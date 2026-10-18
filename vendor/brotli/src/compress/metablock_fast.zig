//! Fast metablock encoding (Quality 2-3 and uncompressed fallback).
//!
//! Handles fast static entropy coding, trivial metablock storage, and uncompressed blocks.

const std = @import("std");
const bit_writer = @import("../bitstream/bit_writer.zig");
const compress_fragment = @import("compress_fragment.zig");
const static_entropy = @import("entropy_encode_static.zig");
const hlmq = @import("hash_longest_match_quickly.zig");
const Command = hlmq.Command;
const fast_log = @import("fast_log.zig");
const constants = @import("../common/constants.zig");

pub const MAX_SIMPLE_DISTANCE_ALPHABET_SIZE: usize = 64;
pub const MAX_HUFFMAN_TREE_SIZE: usize = 2 * constants.NUM_COMMAND_SYMBOLS + 1;

pub const MetablockArena = struct {
    lit_histo: [constants.NUM_LITERAL_SYMBOLS]u32 = @splat(0),
    lit_total: usize = 0,
    cmd_histo: [constants.NUM_COMMAND_SYMBOLS]u32 = @splat(0),
    cmd_total: usize = 0,
    dist_histo: [MAX_SIMPLE_DISTANCE_ALPHABET_SIZE]u32 = @splat(0),
    dist_total: usize = 0,

    lit_depth: [constants.NUM_LITERAL_SYMBOLS]u8 = undefined,
    lit_bits: [constants.NUM_LITERAL_SYMBOLS]u16 = undefined,
    cmd_depth: [constants.NUM_COMMAND_SYMBOLS]u8 = undefined,
    cmd_bits: [constants.NUM_COMMAND_SYMBOLS]u16 = undefined,
    dist_depth: [MAX_SIMPLE_DISTANCE_ALPHABET_SIZE]u8 = undefined,
    dist_bits: [MAX_SIMPLE_DISTANCE_ALPHABET_SIZE]u16 = undefined,
    tree: [MAX_HUFFMAN_TREE_SIZE]compress_fragment.HuffmanTree = undefined,

    pub fn init() MetablockArena {
        return .{};
    }

    pub fn clear(self: *MetablockArena) void {
        @memset(&self.lit_histo, 0);
        self.lit_total = 0;
        @memset(&self.cmd_histo, 0);
        self.cmd_total = 0;
        @memset(&self.dist_histo, 0);
        self.dist_total = 0;
    }
};

pub fn brotliEncodeMlen(length: usize, bits: *u64, numbits: *usize, nibblesbits: *u64) void {
    const lg: usize = std.math.log2_int_ceil(usize, @max(2, length));
    const mnibbles: usize = @max(16, lg + 3) / 4;
    nibblesbits.* = mnibbles - 4;
    numbits.* = mnibbles * 4;
    bits.* = length - 1;
}

pub fn storeCompressedMetaBlockHeader(
    is_final_block: bool,
    length: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    var lenbits: u64 = undefined;
    var nlenbits: usize = undefined;
    var nibblesbits: u64 = undefined;

    bit_writer.writeBits(1, if (is_final_block) 1 else 0, storage_ix, storage);
    if (is_final_block) {
        bit_writer.writeBits(1, 0, storage_ix, storage);
    }

    brotliEncodeMlen(length, &lenbits, &nlenbits, &nibblesbits);
    bit_writer.writeBits(2, nibblesbits, storage_ix, storage);
    bit_writer.writeBits(@intCast(nlenbits), lenbits, storage_ix, storage);

    if (!is_final_block) {
        bit_writer.writeBits(1, 0, storage_ix, storage);
    }
}

pub fn storeUncompressedMetaBlockHeader(length: usize, storage_ix: *usize, storage: []u8) void {
    var lenbits: u64 = undefined;
    var nlenbits: usize = undefined;
    var nibblesbits: u64 = undefined;

    // Write ISLAST bit (0)
    bit_writer.writeBits(1, 0, storage_ix, storage);
    brotliEncodeMlen(length, &lenbits, &nlenbits, &nibblesbits);
    bit_writer.writeBits(2, nibblesbits, storage_ix, storage);
    bit_writer.writeBits(@intCast(nlenbits), lenbits, storage_ix, storage);
    // Write ISUNCOMPRESSED bit (1)
    bit_writer.writeBits(1, 1, storage_ix, storage);
}

pub fn storeUncompressedMetaBlock(
    is_final_block: bool,
    input: []const u8,
    position: usize,
    mask: usize,
    len_in: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    var len = len_in;
    var masked_pos = position & mask;
    storeUncompressedMetaBlockHeader(len, storage_ix, storage);
    bit_writer.jumpToByteBoundary(storage_ix, storage);

    if (mask < std.math.maxInt(usize) and masked_pos + len > mask + 1) {
        const len1 = mask + 1 - masked_pos;
        @memcpy(storage[storage_ix.* >> 3 .. (storage_ix.* >> 3) + len1], input[masked_pos .. masked_pos + len1]);
        storage_ix.* += len1 << 3;
        len -= len1;
        masked_pos = 0;
    }
    @memcpy(storage[storage_ix.* >> 3 .. (storage_ix.* >> 3) + len], input[masked_pos .. masked_pos + len]);
    storage_ix.* += len << 3;

    storage[storage_ix.* >> 3] = 0;

    if (is_final_block) {
        bit_writer.writeBits(1, 1, storage_ix, storage); // islast
        bit_writer.writeBits(1, 1, storage_ix, storage); // isempty
        bit_writer.jumpToByteBoundary(storage_ix, storage);
    }
}

pub fn buildHistograms(
    input: []const u8,
    start_pos: usize,
    mask: usize,
    commands: []const Command,
    arena: *MetablockArena,
) void {
    var pos = start_pos;
    for (commands) |cmd| {
        arena.cmd_histo[cmd.cmd_prefix_] += 1;
        arena.cmd_total += 1;
        var j = cmd.insert_len_;
        while (j != 0) : (j -= 1) {
            arena.lit_histo[input[pos & mask]] += 1;
            arena.lit_total += 1;
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() != 0 and cmd.cmd_prefix_ >= 128) {
            const dist_code = cmd.dist_prefix_ & 0x3FF;
            arena.dist_histo[dist_code] += 1;
            arena.dist_total += 1;
        }
    }
}

pub fn storeDataWithHuffmanCodes(
    input: []const u8,
    start_pos: usize,
    mask: usize,
    commands: []const Command,
    lit_depth: []const u8,
    lit_bits: []const u16,
    cmd_depth: []const u8,
    cmd_bits: []const u16,
    dist_depth: []const u8,
    dist_bits: []const u16,
    storage_ix: *usize,
    storage: []u8,
) void {
    var pos = start_pos;
    for (commands) |cmd| {
        const cmd_code = cmd.cmd_prefix_;
        bit_writer.writeBits(@intCast(cmd_depth[cmd_code]), cmd_bits[cmd_code], storage_ix, storage);
        hlmq.storeCommandExtra(&cmd, storage_ix, storage);
        var j = cmd.insert_len_;
        while (j != 0) : (j -= 1) {
            const lit = input[pos & mask];
            bit_writer.writeBits(@intCast(lit_depth[lit]), lit_bits[lit], storage_ix, storage);
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() != 0 and cmd.cmd_prefix_ >= 128) {
            const dist_code = cmd.dist_prefix_ & 0x3FF;
            const distnumextra = cmd.dist_prefix_ >> 10;
            const distextra = cmd.dist_extra_;
            bit_writer.writeBits(@intCast(dist_depth[dist_code]), dist_bits[dist_code], storage_ix, storage);
            bit_writer.writeBits(@intCast(distnumextra), distextra, storage_ix, storage);
        }
    }
}

pub fn storeSimpleHuffmanTree(
    depths: []const u8,
    symbols_in: *[4]usize,
    num_symbols: usize,
    max_bits: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    bit_writer.writeBits(2, 1, storage_ix, storage);
    bit_writer.writeBits(2, @intCast(num_symbols - 1), storage_ix, storage);

    var i: usize = 0;
    while (i < num_symbols) : (i += 1) {
        var j = i + 1;
        while (j < num_symbols) : (j += 1) {
            if (depths[symbols_in[j]] < depths[symbols_in[i]]) {
                const tmp = symbols_in[i];
                symbols_in[i] = symbols_in[j];
                symbols_in[j] = tmp;
            }
        }
    }

    if (num_symbols == 2) {
        bit_writer.writeBits(@intCast(max_bits), symbols_in[0], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[1], storage_ix, storage);
    } else if (num_symbols == 3) {
        bit_writer.writeBits(@intCast(max_bits), symbols_in[0], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[1], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[2], storage_ix, storage);
    } else {
        bit_writer.writeBits(@intCast(max_bits), symbols_in[0], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[1], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[2], storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols_in[3], storage_ix, storage);
        bit_writer.writeBits(1, if (depths[symbols_in[0]] == 1) 1 else 0, storage_ix, storage);
    }
}

pub fn buildAndStoreHuffmanTree(
    histogram: []const u32,
    histogram_length: usize,
    alphabet_size: usize,
    tree: []compress_fragment.HuffmanTree,
    depth: []u8,
    bits: []u16,
    storage_ix: *usize,
    storage: []u8,
) void {
    var count: usize = 0;
    var s4 = [4]usize{ 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < histogram_length) : (i += 1) {
        if (histogram[i] != 0) {
            if (count < 4) {
                s4[count] = i;
            } else if (count > 4) {
                break;
            }
            count += 1;
        }
    }

    var max_bits: usize = 0;
    var max_bits_counter = alphabet_size - 1;
    while (max_bits_counter != 0) : (max_bits_counter >>= 1) {
        max_bits += 1;
    }

    if (count <= 1) {
        bit_writer.writeBits(4, 1, storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), s4[0], storage_ix, storage);
        depth[s4[0]] = 0;
        bits[s4[0]] = 0;
        return;
    }

    @memset(depth[0..histogram_length], 0);
    compress_fragment.brotliCreateHuffmanTree(histogram[0..histogram_length], 15, tree, depth[0..histogram_length]);
    compress_fragment.brotliConvertBitDepthsToSymbols(depth[0..histogram_length], bits[0..histogram_length]);

    if (count <= 4) {
        storeSimpleHuffmanTree(depth, &s4, count, max_bits, storage_ix, storage);
    } else {
        compress_fragment.brotliStoreHuffmanTree(depth[0..histogram_length], tree, storage_ix, storage);
    }
}

pub fn brotliBitsEntropy(population: []const u32) f64 {
    var sum: usize = 0;
    var retval: f64 = 0;
    for (population) |p_u32| {
        const p: usize = p_u32;
        sum += p;
        retval -= @as(f64, @floatFromInt(p)) * fast_log.fastLog2(p);
    }
    if (sum != 0) {
        retval += @as(f64, @floatFromInt(sum)) * fast_log.fastLog2(sum);
    }
    if (retval < @as(f64, @floatFromInt(sum))) {
        retval = @as(f64, @floatFromInt(sum));
    }
    return retval;
}

pub fn shouldCompress(
    data: []const u8,
    mask: usize,
    last_flush_pos: u64,
    bytes: usize,
    num_literals: usize,
    num_commands: usize,
) bool {
    if (bytes <= 2) return false;
    if (num_commands < (bytes >> 8) + 2) {
        if (@as(f64, @floatFromInt(num_literals)) > 0.99 * @as(f64, @floatFromInt(bytes))) {
            var literal_histo: [256]u32 = @splat(0);
            const kSampleRate: usize = 13;
            const kInvSampleRate: f64 = 1.0 / 13.0;
            const kMinEntropy: f64 = 7.92;
            const bit_cost_threshold = @as(f64, @floatFromInt(bytes)) * kMinEntropy * kInvSampleRate;
            const t = (bytes + kSampleRate - 1) / kSampleRate;
            var pos = @as(usize, @truncate(last_flush_pos));
            var i: usize = 0;
            while (i < t) : (i += 1) {
                literal_histo[data[pos & mask]] += 1;
                pos += kSampleRate;
            }
            if (brotliBitsEntropy(&literal_histo) > bit_cost_threshold) {
                return false;
            }
        }
    }
    return true;
}

pub fn storeMetaBlockFast(
    arena: *MetablockArena,
    input: []const u8,
    start_pos: usize,
    length: usize,
    mask: usize,
    is_last: bool,
    commands: []const Command,
    num_distance_symbols: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    const distance_alphabet_bits = fast_log.log2FloorNonZero(num_distance_symbols - 1) + 1;

    storeCompressedMetaBlockHeader(is_last, length, storage_ix, storage);

    bit_writer.writeBits(13, 0, storage_ix, storage);

    if (commands.len <= 128) {
        var histogram: [constants.NUM_LITERAL_SYMBOLS]u32 = @splat(0);
        var pos = start_pos;
        var num_literals: usize = 0;
        for (commands) |cmd| {
            var j = cmd.insert_len_;
            while (j != 0) : (j -= 1) {
                histogram[input[pos & mask]] += 1;
                pos += 1;
            }
            num_literals += cmd.insert_len_;
            pos += cmd.copyLen();
        }

        compress_fragment.buildAndStoreHuffmanTreeFast(
            &arena.tree,
            &histogram,
            num_literals,
            8,
            &arena.lit_depth,
            &arena.lit_bits,
            storage_ix,
            storage,
        );

        static_entropy.storeStaticCommandHuffmanTree(storage_ix, storage);
        static_entropy.storeStaticDistanceHuffmanTree(storage_ix, storage);

        storeDataWithHuffmanCodes(
            input,
            start_pos,
            mask,
            commands,
            &arena.lit_depth,
            &arena.lit_bits,
            &static_entropy.kStaticCommandCodeDepth,
            &static_entropy.kStaticCommandCodeBits,
            &static_entropy.kStaticDistanceCodeDepth,
            &static_entropy.kStaticDistanceCodeBits,
            storage_ix,
            storage,
        );
    } else {
        arena.clear();
        buildHistograms(input, start_pos, mask, commands, arena);

        compress_fragment.buildAndStoreHuffmanTreeFast(
            &arena.tree,
            &arena.lit_histo,
            arena.lit_total,
            8,
            &arena.lit_depth,
            &arena.lit_bits,
            storage_ix,
            storage,
        );
        compress_fragment.buildAndStoreHuffmanTreeFast(
            &arena.tree,
            &arena.cmd_histo,
            arena.cmd_total,
            10,
            &arena.cmd_depth,
            &arena.cmd_bits,
            storage_ix,
            storage,
        );
        compress_fragment.buildAndStoreHuffmanTreeFast(
            &arena.tree,
            &arena.dist_histo,
            arena.dist_total,
            distance_alphabet_bits,
            &arena.dist_depth,
            &arena.dist_bits,
            storage_ix,
            storage,
        );

        storeDataWithHuffmanCodes(
            input,
            start_pos,
            mask,
            commands,
            &arena.lit_depth,
            &arena.lit_bits,
            &arena.cmd_depth,
            &arena.cmd_bits,
            &arena.dist_depth,
            &arena.dist_bits,
            storage_ix,
            storage,
        );
    }

    if (is_last) {
        bit_writer.jumpToByteBoundary(storage_ix, storage);
    }
}

pub fn storeMetaBlockTrivial(
    arena: *MetablockArena,
    input: []const u8,
    start_pos: usize,
    length: usize,
    mask: usize,
    is_last: bool,
    commands: []const Command,
    num_distance_symbols: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    storeCompressedMetaBlockHeader(is_last, length, storage_ix, storage);

    arena.clear();
    buildHistograms(input, start_pos, mask, commands, arena);

    bit_writer.writeBits(13, 0, storage_ix, storage);

    buildAndStoreHuffmanTree(
        &arena.lit_histo,
        constants.NUM_LITERAL_SYMBOLS,
        constants.NUM_LITERAL_SYMBOLS,
        &arena.tree,
        &arena.lit_depth,
        &arena.lit_bits,
        storage_ix,
        storage,
    );
    buildAndStoreHuffmanTree(
        &arena.cmd_histo,
        constants.NUM_COMMAND_SYMBOLS,
        constants.NUM_COMMAND_SYMBOLS,
        &arena.tree,
        &arena.cmd_depth,
        &arena.cmd_bits,
        storage_ix,
        storage,
    );
    buildAndStoreHuffmanTree(
        &arena.dist_histo,
        MAX_SIMPLE_DISTANCE_ALPHABET_SIZE,
        num_distance_symbols,
        &arena.tree,
        &arena.dist_depth,
        &arena.dist_bits,
        storage_ix,
        storage,
    );

    storeDataWithHuffmanCodes(
        input,
        start_pos,
        mask,
        commands,
        &arena.lit_depth,
        &arena.lit_bits,
        &arena.cmd_depth,
        &arena.cmd_bits,
        &arena.dist_depth,
        &arena.dist_bits,
        storage_ix,
        storage,
    );

    if (is_last) {
        bit_writer.jumpToByteBoundary(storage_ix, storage);
    }
}
