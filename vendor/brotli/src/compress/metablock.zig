//! Block splitting and metablock storage for Quality 4+ compression.
//!
//! Handles greedy metablock construction, context modeling, histogram optimization,
//! and RFC 7932 bitstream emission.

const std = @import("std");
const constants = @import("../common/constants.zig");
const bit_writer = @import("../bitstream/bit_writer.zig");
const compress_fragment = @import("compress_fragment.zig");
const metablock_fast = @import("metablock_fast.zig");
const hlmq = @import("hash_longest_match_quickly.zig");
const Command = hlmq.Command;
const prefix_ranges = @import("../common/prefix_ranges.zig");
const huff_enc = @import("huffman_encode.zig");
const fast_log = @import("fast_log.zig");
const context_mod = @import("../common/context.zig");

pub const BlockSplit = struct {
    num_types: usize = 0,
    num_blocks: usize = 0,
    types: std.ArrayList(u8) = .empty,
    lengths: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *BlockSplit, alloc: std.mem.Allocator) void {
        self.types.deinit(alloc);
        self.lengths.deinit(alloc);
    }

    pub fn clearRetainingCapacity(self: *BlockSplit) void {
        self.num_types = 0;
        self.num_blocks = 0;
        self.types.clearRetainingCapacity();
        self.lengths.clearRetainingCapacity();
    }
};

pub fn BlockSplitter(comptime alphabet_size: usize) type {
    return struct {
        const Self = @This();
        pub const Histogram = struct {
            data: [alphabet_size]u32 = @splat(0),
            total_count: usize = 0,

            pub fn clear(self: *Histogram) void {
                @memset(&self.data, 0);
                self.total_count = 0;
            }

            pub fn addHistogram(self: *Histogram, other: *const Histogram) void {
                for (0..alphabet_size) |i| {
                    self.data[i] += other.data[i];
                }
                self.total_count += other.total_count;
            }
        };

        min_block_size_: usize = 0,
        split_threshold_: f64 = 0,
        num_blocks_: usize = 0,
        split_: *BlockSplit = undefined,
        histograms_: *std.ArrayList(Histogram) = undefined,
        combined_histo: [2]Histogram = undefined,
        target_block_size_: usize = 0,
        block_size_: usize = 0,
        curr_histogram_ix_: usize = 0,
        last_histogram_ix_: [2]usize = .{ 0, 0 },
        last_entropy_: [2]f64 = .{ 0, 0 },
        merge_last_count_: usize = 0,

        pub fn init(
            self: *Self,
            alloc: std.mem.Allocator,
            min_block_size: usize,
            split_threshold: f64,
            num_symbols: usize,
            split: *BlockSplit,
            histograms: *std.ArrayList(Histogram),
        ) !void {
            const max_num_blocks = num_symbols / min_block_size + 1;
            const max_num_types = @min(max_num_blocks, 256 + 1);
            self.min_block_size_ = min_block_size;
            self.split_threshold_ = split_threshold;
            self.num_blocks_ = 0;
            self.split_ = split;
            self.histograms_ = histograms;
            self.target_block_size_ = min_block_size;
            self.block_size_ = 0;
            self.curr_histogram_ix_ = 0;
            self.merge_last_count_ = 0;

            try split.types.ensureTotalCapacity(alloc, max_num_blocks);
            try split.lengths.ensureTotalCapacity(alloc, max_num_blocks);

            try histograms.ensureTotalCapacity(alloc, max_num_types);
            histograms.clearRetainingCapacity();
            try histograms.append(alloc, Histogram{});

            self.last_histogram_ix_[0] = 0;
            self.last_histogram_ix_[1] = 0;
            self.last_entropy_[0] = 0;
            self.last_entropy_[1] = 0;
        }

        pub fn addSymbol(self: *Self, alloc: std.mem.Allocator, symbol: usize) !void {
            self.histograms_.items[self.curr_histogram_ix_].data[symbol] += 1;
            self.histograms_.items[self.curr_histogram_ix_].total_count += 1;
            self.block_size_ += 1;
            if (self.block_size_ == self.target_block_size_) {
                try self.finishBlock(alloc, false);
            }
        }

        pub fn finishBlock(self: *Self, alloc: std.mem.Allocator, is_final: bool) !void {
            self.block_size_ = @max(self.block_size_, self.min_block_size_);
            if (self.num_blocks_ == 0) {
                try self.split_.lengths.append(alloc, @intCast(self.block_size_));
                try self.split_.types.append(alloc, 0);
                self.last_entropy_[0] = metablock_fast.brotliBitsEntropy(&self.histograms_.items[0].data);
                self.last_entropy_[1] = self.last_entropy_[0];
                self.num_blocks_ += 1;
                self.split_.num_types += 1;
                self.curr_histogram_ix_ += 1;
                if (self.curr_histogram_ix_ < self.histograms_.capacity) {
                    if (self.curr_histogram_ix_ >= self.histograms_.items.len) {
                        try self.histograms_.append(alloc, Histogram{});
                    } else {
                        self.histograms_.items[self.curr_histogram_ix_].clear();
                    }
                }
                self.block_size_ = 0;
            } else if (self.block_size_ > 0) {
                const entropy = metablock_fast.brotliBitsEntropy(&self.histograms_.items[self.curr_histogram_ix_].data);
                var combined_entropy: [2]f64 = undefined;
                var diff: [2]f64 = undefined;
                for (0..2) |j| {
                    const last_histogram_ix = self.last_histogram_ix_[j];
                    self.combined_histo[j] = self.histograms_.items[self.curr_histogram_ix_];
                    self.combined_histo[j].addHistogram(&self.histograms_.items[last_histogram_ix]);
                    combined_entropy[j] = metablock_fast.brotliBitsEntropy(&self.combined_histo[j].data);
                    diff[j] = combined_entropy[j] - entropy - self.last_entropy_[j];
                }

                if (self.split_.num_types < 256 and diff[0] > self.split_threshold_ and diff[1] > self.split_threshold_) {
                    try self.split_.lengths.append(alloc, @intCast(self.block_size_));
                    try self.split_.types.append(alloc, @intCast(self.split_.num_types));
                    self.last_histogram_ix_[1] = self.last_histogram_ix_[0];
                    self.last_histogram_ix_[0] = self.split_.num_types;
                    self.last_entropy_[1] = self.last_entropy_[0];
                    self.last_entropy_[0] = entropy;
                    self.num_blocks_ += 1;
                    self.split_.num_types += 1;
                    self.curr_histogram_ix_ += 1;
                    if (self.curr_histogram_ix_ < self.histograms_.capacity) {
                        if (self.curr_histogram_ix_ >= self.histograms_.items.len) {
                            try self.histograms_.append(alloc, Histogram{});
                        } else {
                            self.histograms_.items[self.curr_histogram_ix_].clear();
                        }
                    }
                    self.block_size_ = 0;
                    self.merge_last_count_ = 0;
                    self.target_block_size_ = self.min_block_size_;
                } else if (diff[1] < diff[0] - 20.0) {
                    try self.split_.lengths.append(alloc, @intCast(self.block_size_));
                    try self.split_.types.append(alloc, self.split_.types.items[self.split_.types.items.len - 2]);
                    const tmp = self.last_histogram_ix_[0];
                    self.last_histogram_ix_[0] = self.last_histogram_ix_[1];
                    self.last_histogram_ix_[1] = tmp;
                    self.histograms_.items[self.last_histogram_ix_[0]] = self.combined_histo[1];
                    self.last_entropy_[1] = self.last_entropy_[0];
                    self.last_entropy_[0] = combined_entropy[1];
                    self.num_blocks_ += 1;
                    self.block_size_ = 0;
                    self.histograms_.items[self.curr_histogram_ix_].clear();
                    self.merge_last_count_ = 0;
                    self.target_block_size_ = self.min_block_size_;
                } else {
                    self.split_.lengths.items[self.split_.lengths.items.len - 1] += @intCast(self.block_size_);
                    self.histograms_.items[self.last_histogram_ix_[0]] = self.combined_histo[0];
                    self.last_entropy_[0] = combined_entropy[0];
                    if (self.split_.num_types == 1) {
                        self.last_entropy_[1] = self.last_entropy_[0];
                    }
                    self.block_size_ = 0;
                    self.histograms_.items[self.curr_histogram_ix_].clear();
                    self.merge_last_count_ += 1;
                    if (self.merge_last_count_ > 1) {
                        self.target_block_size_ += self.min_block_size_;
                    }
                }
            }

            if (is_final) {
                self.split_.num_blocks = self.num_blocks_;
            }
        }
    };
}

pub const BlockTypeCodeCalculator = struct {
    last_type: usize = 1,
    second_last_type: usize = 0,

    pub fn nextBlockTypeCode(self: *BlockTypeCodeCalculator, block_type: u8) usize {
        const type_code: usize = if (block_type == self.last_type + 1)
            1
        else if (block_type == self.second_last_type)
            0
        else
            @as(usize, block_type) + 2;
        self.second_last_type = self.last_type;
        self.last_type = block_type;
        return type_code;
    }
};

pub const BlockSplitCode = struct {
    type_code_calculator: BlockTypeCodeCalculator = .{},
    type_depths: [258]u8 = @splat(0),
    type_bits: [258]u16 = @splat(0),
    length_depths: [26]u8 = @splat(0),
    length_bits: [26]u16 = @splat(0),
};

pub inline fn blockLengthPrefixCode(len: u32) u32 {
    return prefix_ranges.findPrefixCode(len);
}

pub fn getBlockLengthPrefixCode(len: u32, code: *usize, n_extra: *u32, extra: *u32) void {
    const c = blockLengthPrefixCode(len);
    code.* = c;
    n_extra.* = prefix_ranges.prefix_code_ranges[c].nbits;
    extra.* = len - prefix_ranges.prefix_code_ranges[c].offset;
}

pub fn storeVarLenUint8(n: usize, storage_ix: *usize, storage: []u8) void {
    if (n == 0) {
        bit_writer.writeBits(1, 0, storage_ix, storage);
    } else {
        const nbits = fast_log.log2FloorNonZero(n);
        bit_writer.writeBits(1, 1, storage_ix, storage);
        bit_writer.writeBits(3, nbits, storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), n - (@as(usize, 1) << @intCast(nbits)), storage_ix, storage);
    }
}

pub fn moveToFrontTransform(v_in: []const u32, v_out: []u32) void {
    if (v_in.len == 0) return;
    const max_val = std.mem.max(u32, v_in);
    var mtf: [256]u8 = undefined;
    for (0..max_val + 1) |i| {
        mtf[i] = @intCast(i);
    }
    const mtf_size = max_val + 1;
    for (v_in, 0..) |val, idx| {
        const target: u8 = @intCast(val);
        const item_idx = std.mem.indexOfScalar(u8, mtf[0..mtf_size], target) orelse mtf_size;
        v_out[idx] = @intCast(item_idx);
        if (item_idx > 0) {
            std.mem.copyBackwards(u8, mtf[1 .. item_idx + 1], mtf[0..item_idx]);
        }
        mtf[0] = target;
    }
}

pub fn runLengthCodeZeros(
    v: []u32,
    out_size: *usize,
    max_run_length_prefix: *u32,
) void {
    const in_size = v.len;
    var max_reps: u32 = 0;
    var i: usize = 0;
    while (i < in_size) {
        while (i < in_size and v[i] != 0) : (i += 1) {}
        var reps: u32 = 0;
        while (i < in_size and v[i] == 0) : (i += 1) {
            reps += 1;
        }
        max_reps = @max(reps, max_reps);
    }
    var max_prefix: u32 = if (max_reps > 0) fast_log.log2FloorNonZero(max_reps) else 0;
    max_prefix = @min(max_prefix, max_run_length_prefix.*);
    max_run_length_prefix.* = max_prefix;
    out_size.* = 0;
    i = 0;
    while (i < in_size) {
        if (v[i] != 0) {
            v[out_size.*] = v[i] + max_prefix;
            i += 1;
            out_size.* += 1;
        } else {
            var reps: u32 = 1;
            var k = i + 1;
            while (k < in_size and v[k] == 0) : (k += 1) reps += 1;
            i += reps;
            while (reps != 0) {
                if (reps < (@as(u32, 2) << @intCast(max_prefix))) {
                    const run_length_prefix = fast_log.log2FloorNonZero(reps);
                    const extra_bits = reps - (@as(u32, 1) << @intCast(run_length_prefix));
                    v[out_size.*] = run_length_prefix + (extra_bits << 9);
                    out_size.* += 1;
                    break;
                } else {
                    const extra_bits = (@as(u32, 1) << @intCast(max_prefix)) - 1;
                    v[out_size.*] = max_prefix + (extra_bits << 9);
                    reps -= (@as(u32, 2) << @intCast(max_prefix)) - 1;
                    out_size.* += 1;
                }
            }
        }
    }
}

pub fn encodeContextMap(
    allocator: std.mem.Allocator,
    context_map: []const u32,
    num_clusters: usize,
    tree: []compress_fragment.HuffmanTree,
    storage_ix: *usize,
    storage: []u8,
) !void {
    storeVarLenUint8(num_clusters - 1, storage_ix, storage);
    if (num_clusters == 1) return;

    const rle_symbols = try allocator.alloc(u32, context_map.len);
    defer allocator.free(rle_symbols);

    moveToFrontTransform(context_map, rle_symbols);
    var max_run_length_prefix: u32 = 6;
    var num_rle_symbols: usize = 0;
    runLengthCodeZeros(rle_symbols, &num_rle_symbols, &max_run_length_prefix);

    const alphabet_size = num_clusters + max_run_length_prefix;
    var histogram: [256 + 16]u32 = @splat(0);
    for (0..num_rle_symbols) |i| {
        histogram[rle_symbols[i] & 0x1FF] += 1;
    }

    const use_rle = max_run_length_prefix > 0;
    bit_writer.writeBits(1, if (use_rle) 1 else 0, storage_ix, storage);
    if (use_rle) {
        bit_writer.writeBits(4, max_run_length_prefix - 1, storage_ix, storage);
    }

    var depths: [256 + 16]u8 = @splat(0);
    var bits: [256 + 16]u16 = @splat(0);
    metablock_fast.buildAndStoreHuffmanTree(&histogram, alphabet_size, alphabet_size, tree, &depths, &bits, storage_ix, storage);

    for (0..num_rle_symbols) |i| {
        const rle_symbol = rle_symbols[i] & 0x1FF;
        const extra_bits_val = rle_symbols[i] >> 9;
        bit_writer.writeBits(@intCast(depths[rle_symbol]), bits[rle_symbol], storage_ix, storage);
        if (rle_symbol > 0 and rle_symbol <= max_run_length_prefix) {
            bit_writer.writeBits(@intCast(rle_symbol), extra_bits_val, storage_ix, storage);
        }
    }
    bit_writer.writeBits(1, 1, storage_ix, storage); // IMTF = 1
}

pub fn storeBlockSwitch(
    code: *BlockSplitCode,
    block_len: u32,
    block_type: u8,
    is_first_block: bool,
    storage_ix: *usize,
    storage: []u8,
) void {
    const typecode = code.type_code_calculator.nextBlockTypeCode(block_type);
    var lencode: usize = undefined;
    var len_nextra: u32 = undefined;
    var len_extra: u32 = undefined;
    if (!is_first_block) {
        bit_writer.writeBits(@intCast(code.type_depths[typecode]), code.type_bits[typecode], storage_ix, storage);
    }
    getBlockLengthPrefixCode(block_len, &lencode, &len_nextra, &len_extra);
    bit_writer.writeBits(@intCast(code.length_depths[lencode]), code.length_bits[lencode], storage_ix, storage);
    bit_writer.writeBits(@intCast(len_nextra), len_extra, storage_ix, storage);
}

pub fn buildAndStoreBlockSplitCode(
    types: []const u8,
    lengths: []const u32,
    num_blocks: usize,
    num_types: usize,
    tree: []compress_fragment.HuffmanTree,
    code: *BlockSplitCode,
    storage_ix: *usize,
    storage: []u8,
) void {
    var type_histo: [258]u32 = @splat(0);
    var length_histo: [26]u32 = @splat(0);
    var calc = BlockTypeCodeCalculator{};
    for (0..num_blocks) |i| {
        const type_code = calc.nextBlockTypeCode(types[i]);
        if (i != 0) type_histo[type_code] += 1;
        length_histo[blockLengthPrefixCode(lengths[i])] += 1;
    }
    storeVarLenUint8(num_types - 1, storage_ix, storage);
    if (num_types > 1) {
        metablock_fast.buildAndStoreHuffmanTree(
            &type_histo,
            num_types + 2,
            num_types + 2,
            tree,
            &code.type_depths,
            &code.type_bits,
            storage_ix,
            storage,
        );
        metablock_fast.buildAndStoreHuffmanTree(
            &length_histo,
            26,
            26,
            tree,
            &code.length_depths,
            &code.length_bits,
            storage_ix,
            storage,
        );
        code.type_code_calculator = BlockTypeCodeCalculator{};
        storeBlockSwitch(code, lengths[0], types[0], true, storage_ix, storage);
    }
}

pub const BlockEncoder = struct {
    histogram_length: usize,
    num_block_types: usize,
    block_types: []const u8,
    block_lengths: []const u32,
    num_blocks: usize,
    block_split_code: BlockSplitCode = .{},
    block_ix: usize = 0,
    block_len: usize = 0,
    entropy_ix: usize = 0,
    depths: []u8,
    bits: []u16,

    pub fn init(
        histogram_length: usize,
        num_block_types: usize,
        block_types: []const u8,
        block_lengths: []const u32,
        num_blocks: usize,
        depths: []u8,
        bits: []u16,
    ) BlockEncoder {
        return .{
            .histogram_length = histogram_length,
            .num_block_types = num_block_types,
            .block_types = block_types,
            .block_lengths = block_lengths,
            .num_blocks = num_blocks,
            .block_len = if (num_blocks == 0) 0 else block_lengths[0],
            .depths = depths,
            .bits = bits,
        };
    }

    pub fn buildAndStoreBlockSwitchEntropyCodes(
        self: *BlockEncoder,
        tree: []compress_fragment.HuffmanTree,
        storage_ix: *usize,
        storage: []u8,
    ) void {
        buildAndStoreBlockSplitCode(
            self.block_types,
            self.block_lengths,
            self.num_blocks,
            self.num_block_types,
            tree,
            &self.block_split_code,
            storage_ix,
            storage,
        );
    }

    pub fn storeSymbol(
        self: *BlockEncoder,
        symbol: usize,
        storage_ix: *usize,
        storage: []u8,
    ) void {
        if (self.block_len == 0) {
            self.block_ix += 1;
            const block_len = self.block_lengths[self.block_ix];
            const block_type = self.block_types[self.block_ix];
            self.block_len = block_len;
            self.entropy_ix = block_type * self.histogram_length;
            storeBlockSwitch(&self.block_split_code, block_len, block_type, false, storage_ix, storage);
        }
        self.block_len -= 1;
        const ix = self.entropy_ix + symbol;
        bit_writer.writeBits(@intCast(self.depths[ix]), self.bits[ix], storage_ix, storage);
    }

    pub fn storeSymbolWithContext(
        self: *BlockEncoder,
        symbol: usize,
        context: usize,
        context_map: []const u32,
        storage_ix: *usize,
        storage: []u8,
        context_bits: u6,
    ) void {
        if (self.block_len == 0) {
            self.block_ix += 1;
            const block_len = self.block_lengths[self.block_ix];
            const block_type = self.block_types[self.block_ix];
            self.block_len = block_len;
            self.entropy_ix = @as(usize, block_type) << @as(std.math.Log2Int(usize), @intCast(context_bits));
            storeBlockSwitch(&self.block_split_code, block_len, block_type, false, storage_ix, storage);
        }
        self.block_len -= 1;
        const histo_ix = context_map[self.entropy_ix + context];
        const ix = histo_ix * self.histogram_length + symbol;
        bit_writer.writeBits(@intCast(self.depths[ix]), self.bits[ix], storage_ix, storage);
    }
};

pub const kStaticContextMapContinuation = [64]u32{
    1, 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

pub const kStaticContextMapSimpleUTF8 = [64]u32{
    0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

fn estimateEntropy(population: []const u32) f64 {
    var total: usize = 0;
    var result: f64 = 0;
    for (population) |p| {
        total += p;
        result += @as(f64, @floatFromInt(p)) * fast_log.fastLog2(p);
    }
    result = @as(f64, @floatFromInt(total)) * fast_log.fastLog2(total) - result;
    return result;
}

pub fn decideOverLiteralContextModeling(
    input: []const u8,
    start_pos: usize,
    length: usize,
    mask: usize,
    quality: u32,
    num_literal_contexts: *usize,
    literal_context_map: *?[]const u32,
) void {
    if (quality < 5 or length < 64) {
        return;
    }
    var bigram_prefix_histo = [9]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const lut = [4]usize{ 0, 0, 1, 2 };
    const end_pos = start_pos + length;
    var s_pos = start_pos;
    while (s_pos + 64 <= end_pos) : (s_pos += 4096) {
        const stride_end = s_pos + 64;
        var prev = lut[input[s_pos & mask] >> 6] * 3;
        var pos = s_pos + 1;
        while (pos < stride_end) : (pos += 1) {
            const lit = input[pos & mask];
            bigram_prefix_histo[prev + lut[lit >> 6]] += 1;
            prev = lut[lit >> 6] * 3;
        }
    }
    var monogram_histo = [3]u32{ 0, 0, 0 };
    var two_prefix_histo = [6]u32{ 0, 0, 0, 0, 0, 0 };
    for (0..9) |i| {
        monogram_histo[i % 3] += bigram_prefix_histo[i];
        two_prefix_histo[i % 6] += bigram_prefix_histo[i];
    }
    var entropy: [4]f64 = .{ 0, 0, 0, 0 };
    entropy[1] = estimateEntropy(&monogram_histo);
    entropy[2] = estimateEntropy(two_prefix_histo[0..3]) + estimateEntropy(two_prefix_histo[3..6]);
    entropy[3] = estimateEntropy(bigram_prefix_histo[0..3]) + estimateEntropy(bigram_prefix_histo[3..6]) + estimateEntropy(bigram_prefix_histo[6..9]);
    const total = monogram_histo[0] + monogram_histo[1] + monogram_histo[2];
    if (total == 0) return;
    entropy[0] = 1.0 / @as(f64, @floatFromInt(total));
    entropy[1] *= entropy[0];
    entropy[2] *= entropy[0];
    entropy[3] *= entropy[0];
    if (quality < 7) {
        entropy[3] = entropy[1] * 10.0;
    }
    if (entropy[1] - entropy[2] < 0.2 and entropy[1] - entropy[3] < 0.2) {
        num_literal_contexts.* = 1;
        literal_context_map.* = null;
    } else if (entropy[2] - entropy[3] < 0.02) {
        num_literal_contexts.* = 2;
        literal_context_map.* = &kStaticContextMapSimpleUTF8;
    } else {
        num_literal_contexts.* = 3;
        literal_context_map.* = &kStaticContextMapContinuation;
    }
}

pub const ContextBlockSplitter = struct {
    pub const Histogram = struct {
        data: [256]u32 = @splat(0),
        total_count: usize = 0,

        pub fn clear(self: *Histogram) void {
            @memset(&self.data, 0);
            self.total_count = 0;
        }

        pub fn addHistogram(self: *Histogram, other: *const Histogram) void {
            for (0..256) |i| {
                self.data[i] += other.data[i];
            }
            self.total_count += other.total_count;
        }
    };

    num_contexts_: usize = 1,
    max_block_types_: usize = 256,
    min_block_size_: usize = 512,
    split_threshold_: f64 = 400.0,
    num_blocks_: usize = 0,
    split_: *BlockSplit = undefined,
    histograms_: *std.ArrayList(Histogram) = undefined,
    target_block_size_: usize = 512,
    block_size_: usize = 0,
    curr_histogram_ix_: usize = 0,
    last_histogram_ix_: [2]usize = .{ 0, 0 },
    last_entropy_: [2 * 4]f64 = @splat(0),
    merge_last_count_: usize = 0,

    pub fn init(
        self: *ContextBlockSplitter,
        alloc: std.mem.Allocator,
        num_contexts: usize,
        min_block_size: usize,
        split_threshold: f64,
        num_symbols: usize,
        split: *BlockSplit,
        histograms: *std.ArrayList(Histogram),
    ) !void {
        const max_num_blocks = num_symbols / min_block_size + 1;
        self.num_contexts_ = num_contexts;
        self.max_block_types_ = 256 / num_contexts;
        self.min_block_size_ = min_block_size;
        self.split_threshold_ = split_threshold;
        self.num_blocks_ = 0;
        self.split_ = split;
        self.histograms_ = histograms;
        self.target_block_size_ = min_block_size;
        self.block_size_ = 0;
        self.curr_histogram_ix_ = 0;
        self.merge_last_count_ = 0;

        try split.types.ensureTotalCapacity(alloc, max_num_blocks);
        try split.lengths.ensureTotalCapacity(alloc, max_num_blocks);

        const max_num_types = @min(max_num_blocks, self.max_block_types_ + 1);
        try histograms.ensureTotalCapacity(alloc, max_num_types * num_contexts);
        histograms.clearRetainingCapacity();
        for (0..num_contexts) |_| {
            try histograms.append(alloc, Histogram{});
        }
        self.last_histogram_ix_[0] = 0;
        self.last_histogram_ix_[1] = 0;
    }

    pub fn finishBlock(self: *ContextBlockSplitter, alloc: std.mem.Allocator, is_final: bool) !void {
        const num_contexts = self.num_contexts_;
        if (self.block_size_ < self.min_block_size_) {
            self.block_size_ = self.min_block_size_;
        }
        if (self.num_blocks_ == 0) {
            try self.split_.lengths.append(alloc, @intCast(self.block_size_));
            try self.split_.types.append(alloc, 0);
            for (0..num_contexts) |i| {
                self.last_entropy_[i] = metablock_fast.brotliBitsEntropy(&self.histograms_.items[i].data);
                self.last_entropy_[num_contexts + i] = self.last_entropy_[i];
            }
            self.num_blocks_ += 1;
            self.split_.num_types += 1;
            self.curr_histogram_ix_ += num_contexts;
            if (self.curr_histogram_ix_ < self.histograms_.capacity) {
                while (self.histograms_.items.len < self.curr_histogram_ix_ + num_contexts) {
                    try self.histograms_.append(alloc, Histogram{});
                }
            }
            self.block_size_ = 0;
        } else if (self.block_size_ > 0) {
            var entropy: [4]f64 = @splat(0);
            var combined_histo: [2 * 4]Histogram = undefined;
            var combined_entropy: [2 * 4]f64 = @splat(0);
            var diff: [2]f64 = .{ 0.0, 0.0 };

            for (0..num_contexts) |i| {
                const curr_histo_ix = self.curr_histogram_ix_ + i;
                entropy[i] = metablock_fast.brotliBitsEntropy(&self.histograms_.items[curr_histo_ix].data);
                for (0..2) |j| {
                    const jx = j * num_contexts + i;
                    const last_histogram_ix = self.last_histogram_ix_[j] + i;
                    combined_histo[jx] = self.histograms_.items[curr_histo_ix];
                    combined_histo[jx].addHistogram(&self.histograms_.items[last_histogram_ix]);
                    combined_entropy[jx] = metablock_fast.brotliBitsEntropy(&combined_histo[jx].data);
                    diff[j] += combined_entropy[jx] - entropy[i] - self.last_entropy_[jx];
                }
            }

            if (self.split_.num_types < self.max_block_types_ and
                diff[0] > self.split_threshold_ and
                diff[1] > self.split_threshold_)
            {
                // Create new block
                try self.split_.lengths.append(alloc, @intCast(self.block_size_));
                try self.split_.types.append(alloc, @intCast(self.split_.num_types));
                self.last_histogram_ix_[1] = self.last_histogram_ix_[0];
                self.last_histogram_ix_[0] = self.split_.num_types * num_contexts;
                for (0..num_contexts) |i| {
                    self.last_entropy_[num_contexts + i] = self.last_entropy_[i];
                    self.last_entropy_[i] = entropy[i];
                }
                self.num_blocks_ += 1;
                self.split_.num_types += 1;
                self.curr_histogram_ix_ += num_contexts;
                if (self.curr_histogram_ix_ < self.histograms_.capacity) {
                    while (self.histograms_.items.len < self.curr_histogram_ix_ + num_contexts) {
                        try self.histograms_.append(alloc, Histogram{});
                    }
                }
                self.block_size_ = 0;
                self.merge_last_count_ = 0;
                self.target_block_size_ = self.min_block_size_;
            } else if (diff[1] < diff[0] - 20.0) {
                // Combine with second last block
                try self.split_.lengths.append(alloc, @intCast(self.block_size_));
                try self.split_.types.append(alloc, self.split_.types.items[self.num_blocks_ - 2]);
                std.mem.swap(usize, &self.last_histogram_ix_[0], &self.last_histogram_ix_[1]);
                for (0..num_contexts) |i| {
                    self.histograms_.items[self.last_histogram_ix_[0] + i] = combined_histo[num_contexts + i];
                    self.last_entropy_[num_contexts + i] = self.last_entropy_[i];
                    self.last_entropy_[i] = combined_entropy[num_contexts + i];
                    self.histograms_.items[self.curr_histogram_ix_ + i].clear();
                }
                self.num_blocks_ += 1;
                self.block_size_ = 0;
                self.merge_last_count_ = 0;
                self.target_block_size_ = self.min_block_size_;
            } else {
                // Combine with last block
                self.split_.lengths.items[self.num_blocks_ - 1] += @intCast(self.block_size_);
                for (0..num_contexts) |i| {
                    self.histograms_.items[self.last_histogram_ix_[0] + i] = combined_histo[i];
                    self.last_entropy_[i] = combined_entropy[i];
                    if (self.split_.num_types == 1) {
                        self.last_entropy_[num_contexts + i] = self.last_entropy_[i];
                    }
                    self.histograms_.items[self.curr_histogram_ix_ + i].clear();
                }
                self.block_size_ = 0;
                self.merge_last_count_ += 1;
                if (self.merge_last_count_ > 1) {
                    self.target_block_size_ += self.min_block_size_;
                }
            }
        }
        if (is_final) {
            self.split_.num_blocks = self.num_blocks_;
        }
    }

    pub fn addSymbol(self: *ContextBlockSplitter, alloc: std.mem.Allocator, symbol: u8, context: usize) !void {
        const hist = &self.histograms_.items[self.curr_histogram_ix_ + context];
        hist.data[symbol] += 1;
        hist.total_count += 1;
        self.block_size_ += 1;
        if (self.block_size_ == self.target_block_size_) {
            try self.finishBlock(alloc, false);
        }
    }
};

pub const MetaBlockArena = struct {
    lit_split: BlockSplit = .{},
    cmd_split: BlockSplit = .{},
    dist_split: BlockSplit = .{},

    lit_histograms: std.ArrayList(ContextBlockSplitter.Histogram) = .empty,
    cmd_histograms: std.ArrayList(BlockSplitter(704).Histogram) = .empty,
    dist_histograms: std.ArrayList(BlockSplitter(64).Histogram) = .empty,

    tree: [metablock_fast.MAX_HUFFMAN_TREE_SIZE]compress_fragment.HuffmanTree = undefined,

    pub fn init() MetaBlockArena {
        return .{};
    }

    pub fn deinit(self: *MetaBlockArena, alloc: std.mem.Allocator) void {
        self.lit_split.deinit(alloc);
        self.cmd_split.deinit(alloc);
        self.dist_split.deinit(alloc);
        self.lit_histograms.deinit(alloc);
        self.cmd_histograms.deinit(alloc);
        self.dist_histograms.deinit(alloc);
    }

    pub fn clearRetainingCapacity(self: *MetaBlockArena) void {
        self.lit_split.clearRetainingCapacity();
        self.cmd_split.clearRetainingCapacity();
        self.dist_split.clearRetainingCapacity();
        self.lit_histograms.clearRetainingCapacity();
        self.cmd_histograms.clearRetainingCapacity();
        self.dist_histograms.clearRetainingCapacity();
    }
};

pub fn storeMetaBlockGreedy(
    allocator: std.mem.Allocator,
    arena: *MetaBlockArena,
    input: []const u8,
    start_pos: usize,
    length: usize,
    mask: usize,
    is_last: bool,
    commands: []const Command,
    num_distance_symbols: usize,
    quality: u32,
    storage_ix: *usize,
    storage: []u8,
) !void {
    arena.clearRetainingCapacity();

    var num_literals: usize = 0;
    for (commands) |cmd| {
        num_literals += cmd.insert_len_;
    }

    // Decide over literal context modeling:
    var num_literal_contexts: usize = 1;
    var literal_context_map: ?[]const u32 = null;
    decideOverLiteralContextModeling(input, start_pos, length, mask, quality, &num_literal_contexts, &literal_context_map);

    var lit_splitter = ContextBlockSplitter{};
    try lit_splitter.init(allocator, num_literal_contexts, 512, 400.0, num_literals, &arena.lit_split, &arena.lit_histograms);

    var cmd_splitter = BlockSplitter(704){};
    try cmd_splitter.init(allocator, 1024, 500.0, commands.len, &arena.cmd_split, &arena.cmd_histograms);

    var dist_splitter = BlockSplitter(64){};
    try dist_splitter.init(allocator, 512, 100.0, commands.len, &arena.dist_split, &arena.dist_histograms);

    var pos: usize = start_pos;
    var prev_byte: u8 = if (start_pos > 0) input[(start_pos - 1) & mask] else 0;
    var prev_byte2: u8 = if (start_pos > 1) input[(start_pos - 2) & mask] else 0;

    for (commands) |cmd| {
        try cmd_splitter.addSymbol(allocator, cmd.cmd_prefix_);
        var j = cmd.insert_len_;
        while (j != 0) : (j -= 1) {
            const lit = input[pos & mask];
            if (num_literal_contexts == 1) {
                try lit_splitter.addSymbol(allocator, lit, 0);
            } else {
                const ctx = context_mod.contextId(prev_byte, prev_byte2, .utf8);
                const mapped_ctx = literal_context_map.?[ctx];
                try lit_splitter.addSymbol(allocator, lit, mapped_ctx);
            }
            prev_byte2 = prev_byte;
            prev_byte = lit;
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() > 0) {
            prev_byte2 = input[(pos - 2) & mask];
            prev_byte = input[(pos - 1) & mask];
            if (cmd.cmd_prefix_ >= 128) {
                try dist_splitter.addSymbol(allocator, cmd.dist_prefix_ & 0x3FF);
            }
        }
    }

    try lit_splitter.finishBlock(allocator, true);
    try cmd_splitter.finishBlock(allocator, true);
    try dist_splitter.finishBlock(allocator, true);

    const total_lit_histograms = arena.lit_split.num_types * num_literal_contexts;

    // Optimize histograms for RLE
    for (arena.lit_histograms.items[0..total_lit_histograms]) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data);
    }
    for (arena.cmd_histograms.items[0..arena.cmd_split.num_types]) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data);
    }
    for (arena.dist_histograms.items[0..arena.dist_split.num_types]) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data);
    }

    // Store compressed metablock header
    metablock_fast.storeCompressedMetaBlockHeader(is_last, length, storage_ix, storage);

    const tree = &arena.tree;

    const lit_depths = try allocator.alloc(u8, total_lit_histograms * 256);
    defer allocator.free(lit_depths);
    const lit_bits = try allocator.alloc(u16, total_lit_histograms * 256);
    defer allocator.free(lit_bits);

    const cmd_depths = try allocator.alloc(u8, arena.cmd_split.num_types * 704);
    defer allocator.free(cmd_depths);
    const cmd_bits = try allocator.alloc(u16, arena.cmd_split.num_types * 704);
    defer allocator.free(cmd_bits);

    const dist_depths = try allocator.alloc(u8, arena.dist_split.num_types * 64);
    defer allocator.free(dist_depths);
    const dist_bits = try allocator.alloc(u16, arena.dist_split.num_types * 64);
    defer allocator.free(dist_bits);

    var lit_enc = BlockEncoder.init(256, arena.lit_split.num_types, arena.lit_split.types.items, arena.lit_split.lengths.items, arena.lit_split.num_blocks, lit_depths, lit_bits);
    var cmd_enc = BlockEncoder.init(704, arena.cmd_split.num_types, arena.cmd_split.types.items, arena.cmd_split.lengths.items, arena.cmd_split.num_blocks, cmd_depths, cmd_bits);
    var dist_enc = BlockEncoder.init(64, arena.dist_split.num_types, arena.dist_split.types.items, arena.dist_split.lengths.items, arena.dist_split.num_blocks, dist_depths, dist_bits);

    lit_enc.buildAndStoreBlockSwitchEntropyCodes(tree, storage_ix, storage);
    cmd_enc.buildAndStoreBlockSwitchEntropyCodes(tree, storage_ix, storage);
    dist_enc.buildAndStoreBlockSwitchEntropyCodes(tree, storage_ix, storage);

    // Distance params: postfix=0, direct=0
    bit_writer.writeBits(2, 0, storage_ix, storage);
    bit_writer.writeBits(4, 0, storage_ix, storage);

    // Context mode: CONTEXT_UTF8 = 2 for each lit block type
    for (0..arena.lit_split.num_types) |_| {
        bit_writer.writeBits(2, 2, storage_ix, storage);
    }

    // Store literal context map
    var full_lit_context_map: ?[]u32 = null;
    if (num_literal_contexts > 1) {
        full_lit_context_map = try allocator.alloc(u32, arena.lit_split.num_types << 6);
        for (0..arena.lit_split.num_types) |t_idx| {
            const offset: u32 = @intCast(t_idx * num_literal_contexts);
            for (0..64) |c_idx| {
                full_lit_context_map.?[(t_idx << 6) + c_idx] = offset + literal_context_map.?[c_idx];
            }
        }
        try encodeContextMap(allocator, full_lit_context_map.?, total_lit_histograms, tree, storage_ix, storage);
    } else {
        // Trivial context map
        storeVarLenUint8(arena.lit_split.num_types - 1, storage_ix, storage);
        if (arena.lit_split.num_types > 1) {
            const repeat_code: usize = 5; // 6 - 1
            const repeat_bits: usize = 31; // (1 << 5) - 1
            const alphabet_size = arena.lit_split.num_types + repeat_code;
            var histo: [256 + 16]u32 = @splat(0);
            var depths: [256 + 16]u8 = @splat(0);
            var bits: [256 + 16]u16 = @splat(0);
            bit_writer.writeBits(1, 1, storage_ix, storage); // RLEMAX
            bit_writer.writeBits(4, repeat_code - 1, storage_ix, storage);
            histo[repeat_code] = @intCast(arena.lit_split.num_types);
            histo[0] = 1;
            for (6..alphabet_size) |i| histo[i] = 1;
            metablock_fast.buildAndStoreHuffmanTree(&histo, alphabet_size, alphabet_size, tree, &depths, &bits, storage_ix, storage);
            for (0..arena.lit_split.num_types) |i| {
                const code = if (i == 0) 0 else i + 6 - 1;
                bit_writer.writeBits(@intCast(depths[code]), bits[code], storage_ix, storage);
                bit_writer.writeBits(@intCast(depths[repeat_code]), bits[repeat_code], storage_ix, storage);
                bit_writer.writeBits(repeat_code, repeat_bits, storage_ix, storage);
            }
            bit_writer.writeBits(1, 1, storage_ix, storage); // IMTF
        }
    }
    defer if (full_lit_context_map) |m| allocator.free(m);

    // Distance context map: trivial
    storeVarLenUint8(arena.dist_split.num_types - 1, storage_ix, storage);
    if (arena.dist_split.num_types > 1) {
        const repeat_code: usize = 1; // 2 - 1
        const repeat_bits: usize = 1;
        const alphabet_size = arena.dist_split.num_types + repeat_code;
        var histo: [256 + 16]u32 = @splat(0);
        var depths: [256 + 16]u8 = @splat(0);
        var bits: [256 + 16]u16 = @splat(0);
        bit_writer.writeBits(1, 1, storage_ix, storage);
        bit_writer.writeBits(4, repeat_code - 1, storage_ix, storage);
        histo[repeat_code] = @intCast(arena.dist_split.num_types);
        histo[0] = 1;
        for (2..alphabet_size) |i| histo[i] = 1;
        metablock_fast.buildAndStoreHuffmanTree(&histo, alphabet_size, alphabet_size, tree, &depths, &bits, storage_ix, storage);
        for (0..arena.dist_split.num_types) |i| {
            const code = if (i == 0) 0 else i + 2 - 1;
            bit_writer.writeBits(@intCast(depths[code]), bits[code], storage_ix, storage);
            bit_writer.writeBits(@intCast(depths[repeat_code]), bits[repeat_code], storage_ix, storage);
            bit_writer.writeBits(repeat_code, repeat_bits, storage_ix, storage);
        }
        bit_writer.writeBits(1, 1, storage_ix, storage);
    }

    // Build and store entropy codes for each block type / context
    for (0..total_lit_histograms) |i| {
        const ix = i * 256;
        metablock_fast.buildAndStoreHuffmanTree(
            &arena.lit_histograms.items[i].data,
            256,
            256,
            tree,
            lit_depths[ix .. ix + 256],
            lit_bits[ix .. ix + 256],
            storage_ix,
            storage,
        );
    }
    for (0..arena.cmd_split.num_types) |i| {
        const ix = i * 704;
        metablock_fast.buildAndStoreHuffmanTree(
            &arena.cmd_histograms.items[i].data,
            704,
            704,
            tree,
            cmd_depths[ix .. ix + 704],
            cmd_bits[ix .. ix + 704],
            storage_ix,
            storage,
        );
    }
    for (0..arena.dist_split.num_types) |i| {
        const ix = i * 64;
        metablock_fast.buildAndStoreHuffmanTree(
            &arena.dist_histograms.items[i].data,
            64,
            num_distance_symbols,
            tree,
            dist_depths[ix .. ix + 64],
            dist_bits[ix .. ix + 64],
            storage_ix,
            storage,
        );
    }

    // Emit symbols
    pos = start_pos;
    prev_byte = if (start_pos > 0) input[(start_pos - 1) & mask] else 0;
    prev_byte2 = if (start_pos > 1) input[(start_pos - 2) & mask] else 0;

    for (commands) |cmd| {
        cmd_enc.storeSymbol(cmd.cmd_prefix_, storage_ix, storage);
        hlmq.storeCommandExtra(&cmd, storage_ix, storage);
        var j = cmd.insert_len_;
        while (j != 0) : (j -= 1) {
            const lit = input[pos & mask];
            if (num_literal_contexts == 1) {
                lit_enc.storeSymbol(lit, storage_ix, storage);
            } else {
                const ctx = context_mod.contextId(prev_byte, prev_byte2, .utf8);
                lit_enc.storeSymbolWithContext(lit, ctx, full_lit_context_map.?, storage_ix, storage, 6);
            }
            prev_byte2 = prev_byte;
            prev_byte = lit;
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() > 0) {
            prev_byte2 = input[(pos - 2) & mask];
            prev_byte = input[(pos - 1) & mask];
            if (cmd.cmd_prefix_ >= 128) {
                dist_enc.storeSymbol(cmd.dist_prefix_ & 0x3FF, storage_ix, storage);
                bit_writer.writeBits(@intCast(cmd.dist_prefix_ >> 10), cmd.dist_extra_, storage_ix, storage);
            }
        }
    }

    if (is_last) {
        bit_writer.jumpToByteBoundary(storage_ix, storage);
    }
}
