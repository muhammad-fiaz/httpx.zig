//! High-quality metablock building, block splitting, clustering, and storage
//! for Quality 10 and 11 compression (RFC 7932).
//!
//! Provides optimal histogram clustering, dynamic distance parameter tuning,
//! multi-pass block splitting, and entropy-coded metablock serialization.

const std = @import("std");
const constants = @import("../common/constants.zig");
const bit_writer = @import("../bitstream/bit_writer.zig");
const compress_fragment = @import("compress_fragment.zig");
const metablock_fast = @import("metablock_fast.zig");
const metablock = @import("metablock.zig");
const BlockSplit = metablock.BlockSplit;
const BlockEncoder = metablock.BlockEncoder;
const encodeContextMap = metablock.encodeContextMap;
const storeVarLenUint8 = metablock.storeVarLenUint8;
const hlmq = @import("hash_longest_match_quickly.zig");
const Command = hlmq.Command;
const huff_enc = @import("huffman_encode.zig");
const fast_log = @import("fast_log.zig");
const context_mod = @import("../common/context.zig");

pub fn Histogram(comptime alphabet_size: usize) type {
    return struct {
        const Self = @This();
        pub const ALPHABET_SIZE = alphabet_size;

        data_: [alphabet_size]u32 = @splat(0),
        total_count_: usize = 0,
        bit_cost_: f64 = 0,

        pub inline fn clear(self: *Self) void {
            @memset(&self.data_, 0);
            self.total_count_ = 0;
            self.bit_cost_ = 0;
        }

        pub inline fn add(self: *Self, val: usize) void {
            self.data_[val] += 1;
            self.total_count_ += 1;
        }

        pub inline fn addVector(self: *Self, slice: anytype) void {
            for (slice) |val| {
                self.data_[val] += 1;
            }
            self.total_count_ += slice.len;
        }

        pub inline fn addHistogram(self: *Self, other: *const Self) void {
            for (0..alphabet_size) |i| {
                self.data_[i] += other.data_[i];
            }
            self.total_count_ += other.total_count_;
        }
    };
}

pub const HistogramLiteral = Histogram(256);
pub const HistogramCommand = Histogram(704);
pub const HistogramDistance = Histogram(544);

pub fn brotliPopulationCost(comptime alphabet_size: usize, histo: *const Histogram(alphabet_size)) f64 {
    const kOneSymbolHistogramCost: f64 = 12.0;
    const kTwoSymbolHistogramCost: f64 = 20.0;
    const kThreeSymbolHistogramCost: f64 = 28.0;
    const kFourSymbolHistogramCost: f64 = 37.0;

    if (histo.total_count_ == 0) return kOneSymbolHistogramCost;

    var count: usize = 0;
    var s: [5]usize = undefined;
    for (0..alphabet_size) |i| {
        if (histo.data_[i] > 0) {
            s[count] = i;
            count += 1;
            if (count > 4) break;
        }
    }

    if (count == 1) return kOneSymbolHistogramCost;
    if (count == 2) {
        return kTwoSymbolHistogramCost + @as(f64, @floatFromInt(histo.total_count_));
    }
    if (count == 3) {
        const h0 = histo.data_[s[0]];
        const h1 = histo.data_[s[1]];
        const h2 = histo.data_[s[2]];
        const hmax = @max(h0, @max(h1, h2));
        return kThreeSymbolHistogramCost + @as(f64, @floatFromInt(2 * (h0 + h1 + h2) - hmax));
    }
    if (count == 4) {
        var h = [4]u32{
            histo.data_[s[0]],
            histo.data_[s[1]],
            histo.data_[s[2]],
            histo.data_[s[3]],
        };
        std.mem.sort(u32, &h, {}, std.sort.desc(u32));
        const h23 = h[2] + h[3];
        const hmax = @max(h23, h[0]);
        return kFourSymbolHistogramCost + @as(f64, @floatFromInt(3 * h23 + 2 * (h[0] + h[1]) - hmax));
    }

    var bits: f64 = 0.0;
    var max_depth: usize = 1;
    var depth_histo: [18]u32 = @splat(0);
    const log2total = fast_log.fastLog2(histo.total_count_);

    var i: usize = 0;
    while (i < alphabet_size) {
        if (histo.data_[i] > 0) {
            const log2p = log2total - fast_log.fastLog2(histo.data_[i]);
            var depth: usize = @intFromFloat(log2p + 0.5);
            bits += @as(f64, @floatFromInt(histo.data_[i])) * log2p;
            if (depth > 15) depth = 15;
            if (depth > max_depth) max_depth = depth;
            depth_histo[depth] += 1;
            i += 1;
        } else {
            var reps: u32 = 1;
            var k = i + 1;
            while (k < alphabet_size and histo.data_[k] == 0) : (k += 1) {
                reps += 1;
            }
            i += reps;
            if (i == alphabet_size) break;
            if (reps < 3) {
                depth_histo[0] += reps;
            } else {
                reps -= 2;
                while (reps > 0) {
                    depth_histo[17] += 1;
                    bits += 3.0;
                    reps >>= 3;
                }
            }
        }
    }

    bits += @as(f64, @floatFromInt(18 + 2 * max_depth));
    bits += metablock_fast.brotliBitsEntropy(&depth_histo);
    return bits;
}

pub inline fn clusterCostDiff(size_a: usize, size_b: usize) f64 {
    const size_c = size_a + size_b;
    return @as(f64, @floatFromInt(size_a)) * fast_log.fastLog2(size_a) +
        @as(f64, @floatFromInt(size_b)) * fast_log.fastLog2(size_b) -
        @as(f64, @floatFromInt(size_c)) * fast_log.fastLog2(size_c);
}

pub const HistogramPair = struct {
    idx1: u32 = 0,
    idx2: u32 = 0,
    cost_diff: f64 = 0,
    cost_combo: f64 = 0,

    pub inline fn isLess(p1: *const HistogramPair, p2: *const HistogramPair) bool {
        if (p1.cost_diff != p2.cost_diff) {
            return p1.cost_diff > p2.cost_diff;
        }
        return (p1.idx2 - p1.idx1) > (p2.idx2 - p2.idx1);
    }
};

fn compareAndPushToQueue(
    comptime alphabet_size: usize,
    out: []const Histogram(alphabet_size),
    tmp: *Histogram(alphabet_size),
    cluster_size: []const u32,
    idx1_in: u32,
    idx2_in: u32,
    max_num_pairs: usize,
    pairs: []HistogramPair,
    num_pairs: *usize,
) void {
    if (idx1_in == idx2_in) return;
    var idx1 = idx1_in;
    var idx2 = idx2_in;
    if (idx2 < idx1) {
        const t = idx2;
        idx2 = idx1;
        idx1 = t;
    }

    var is_good_pair = false;
    var p = HistogramPair{
        .idx1 = idx1,
        .idx2 = idx2,
        .cost_diff = 0.5 * clusterCostDiff(cluster_size[idx1], cluster_size[idx2]) - out[idx1].bit_cost_ - out[idx2].bit_cost_,
        .cost_combo = 0,
    };

    if (out[idx1].total_count_ == 0) {
        p.cost_combo = out[idx2].bit_cost_;
        is_good_pair = true;
    } else if (out[idx2].total_count_ == 0) {
        p.cost_combo = out[idx1].bit_cost_;
        is_good_pair = true;
    } else {
        const threshold: f64 = if (num_pairs.* == 0) 1e99 else @max(0.0, pairs[0].cost_diff);
        tmp.* = out[idx1];
        tmp.addHistogram(&out[idx2]);
        const cost_combo = brotliPopulationCost(alphabet_size, tmp);
        if (cost_combo < threshold - p.cost_diff) {
            p.cost_combo = cost_combo;
            is_good_pair = true;
        }
    }

    if (is_good_pair) {
        p.cost_diff += p.cost_combo;
        if (num_pairs.* > 0 and HistogramPair.isLess(&pairs[0], &p)) {
            if (num_pairs.* < max_num_pairs) {
                pairs[num_pairs.*] = pairs[0];
                num_pairs.* += 1;
            }
            pairs[0] = p;
        } else if (num_pairs.* < max_num_pairs) {
            pairs[num_pairs.*] = p;
            num_pairs.* += 1;
        }
    }
}

fn histogramCombine(
    comptime alphabet_size: usize,
    out: []Histogram(alphabet_size),
    tmp: *Histogram(alphabet_size),
    cluster_size: []u32,
    symbols: []u32,
    clusters: []u32,
    pairs: []HistogramPair,
    num_clusters_in: usize,
    symbols_size: usize,
    max_clusters: usize,
    max_num_pairs: usize,
) usize {
    var cost_diff_threshold: f64 = 0.0;
    var min_cluster_size: usize = 1;
    var num_pairs: usize = 0;
    var num_clusters = num_clusters_in;

    for (0..num_clusters) |idx1| {
        var idx2 = idx1 + 1;
        while (idx2 < num_clusters) : (idx2 += 1) {
            compareAndPushToQueue(
                alphabet_size,
                out,
                tmp,
                cluster_size,
                clusters[idx1],
                clusters[idx2],
                max_num_pairs,
                pairs,
                &num_pairs,
            );
        }
    }

    while (num_clusters > min_cluster_size) {
        if (pairs[0].cost_diff >= cost_diff_threshold) {
            cost_diff_threshold = 1e99;
            min_cluster_size = max_clusters;
            continue;
        }

        const best_idx1 = pairs[0].idx1;
        const best_idx2 = pairs[0].idx2;
        out[best_idx1].addHistogram(&out[best_idx2]);
        out[best_idx1].bit_cost_ = pairs[0].cost_combo;
        cluster_size[best_idx1] += cluster_size[best_idx2];

        for (0..symbols_size) |i| {
            if (symbols[i] == best_idx2) {
                symbols[i] = best_idx1;
            }
        }
        for (0..num_clusters) |i| {
            if (clusters[i] == best_idx2) {
                std.mem.copyForwards(u32, clusters[i .. num_clusters - 1], clusters[i + 1 .. num_clusters]);
                break;
            }
        }
        num_clusters -= 1;

        var copy_to_idx: usize = 0;
        for (0..num_pairs) |i| {
            const p = pairs[i];
            if (p.idx1 == best_idx1 or p.idx2 == best_idx1 or p.idx1 == best_idx2 or p.idx2 == best_idx2) {
                continue;
            }
            if (HistogramPair.isLess(&pairs[0], &p)) {
                const front = pairs[0];
                pairs[0] = p;
                pairs[copy_to_idx] = front;
            } else {
                pairs[copy_to_idx] = p;
            }
            copy_to_idx += 1;
        }
        num_pairs = copy_to_idx;

        for (0..num_clusters) |i| {
            compareAndPushToQueue(
                alphabet_size,
                out,
                tmp,
                cluster_size,
                best_idx1,
                clusters[i],
                max_num_pairs,
                pairs,
                &num_pairs,
            );
        }
    }

    return num_clusters;
}

inline fn histogramBitCostDistance(
    comptime alphabet_size: usize,
    histogram: *const Histogram(alphabet_size),
    candidate: *const Histogram(alphabet_size),
    tmp: *Histogram(alphabet_size),
) f64 {
    if (histogram.total_count_ == 0) return 0.0;
    tmp.* = histogram.*;
    tmp.addHistogram(candidate);
    return brotliPopulationCost(alphabet_size, tmp) - candidate.bit_cost_;
}

fn histogramRemap(
    comptime alphabet_size: usize,
    in: []const Histogram(alphabet_size),
    in_size: usize,
    clusters: []const u32,
    num_clusters: usize,
    out: []Histogram(alphabet_size),
    tmp: *Histogram(alphabet_size),
    symbols: []u32,
) void {
    for (0..in_size) |i| {
        var best_out: u32 = if (i == 0) symbols[0] else symbols[i - 1];
        var best_bits = histogramBitCostDistance(alphabet_size, &in[i], &out[best_out], tmp);
        for (0..num_clusters) |j| {
            const cur_bits = histogramBitCostDistance(alphabet_size, &in[i], &out[clusters[j]], tmp);
            if (cur_bits < best_bits) {
                best_bits = cur_bits;
                best_out = clusters[j];
            }
        }
        symbols[i] = best_out;
    }

    for (0..num_clusters) |i| {
        out[clusters[i]].clear();
    }
    for (0..in_size) |i| {
        out[symbols[i]].addHistogram(&in[i]);
    }
}

fn histogramReindex(
    allocator: std.mem.Allocator,
    comptime alphabet_size: usize,
    out: []Histogram(alphabet_size),
    symbols: []u32,
    length: usize,
) !usize {
    const new_index = try allocator.alloc(u32, length);
    defer allocator.free(new_index);
    @memset(new_index, std.math.maxInt(u32));

    var next_index: u32 = 0;
    for (0..length) |i| {
        if (new_index[symbols[i]] == std.math.maxInt(u32)) {
            new_index[symbols[i]] = next_index;
            next_index += 1;
        }
    }

    const tmp = try allocator.alloc(Histogram(alphabet_size), next_index);
    defer allocator.free(tmp);

    next_index = 0;
    for (0..length) |i| {
        if (new_index[symbols[i]] == next_index) {
            tmp[next_index] = out[symbols[i]];
            next_index += 1;
        }
        symbols[i] = new_index[symbols[i]];
    }

    for (0..next_index) |i| {
        out[i] = tmp[i];
    }
    return next_index;
}

pub fn clusterHistograms(
    allocator: std.mem.Allocator,
    comptime alphabet_size: usize,
    in: []const Histogram(alphabet_size),
    in_size: usize,
    max_histograms: usize,
    out: []Histogram(alphabet_size),
    out_size: *usize,
    histogram_symbols: []u32,
) !void {
    const cluster_size = try allocator.alloc(u32, in_size);
    defer allocator.free(cluster_size);
    @memset(cluster_size, 1);

    const clusters = try allocator.alloc(u32, in_size);
    defer allocator.free(clusters);

    const max_input_histograms: usize = 64;
    const pairs_capacity: usize = max_input_histograms * max_input_histograms / 2 + 1;
    var pairs_list = try std.ArrayList(HistogramPair).initCapacity(allocator, pairs_capacity);
    defer pairs_list.deinit(allocator);
    pairs_list.appendNTimesAssumeCapacity(HistogramPair{}, pairs_capacity);

    var tmp: Histogram(alphabet_size) = undefined;
    var num_clusters: usize = 0;

    for (0..in_size) |i| {
        out[i] = in[i];
        out[i].bit_cost_ = brotliPopulationCost(alphabet_size, &in[i]);
        histogram_symbols[i] = @intCast(i);
    }

    var i: usize = 0;
    while (i < in_size) : (i += max_input_histograms) {
        const num_to_combine = @min(in_size - i, max_input_histograms);
        for (0..num_to_combine) |j| {
            clusters[num_clusters + j] = @intCast(i + j);
        }
        const num_new_clusters = histogramCombine(
            alphabet_size,
            out,
            &tmp,
            cluster_size,
            histogram_symbols[i .. i + num_to_combine],
            clusters[num_clusters .. num_clusters + num_to_combine],
            pairs_list.items,
            num_to_combine,
            num_to_combine,
            max_histograms,
            pairs_capacity - 1,
        );
        num_clusters += num_new_clusters;
    }

    const max_num_pairs = @min(64 * num_clusters, (num_clusters / 2) * num_clusters);
    if (pairs_list.items.len < max_num_pairs + 1) {
        try pairs_list.resize(allocator, max_num_pairs + 1);
    }

    num_clusters = histogramCombine(
        alphabet_size,
        out,
        &tmp,
        cluster_size,
        histogram_symbols[0..in_size],
        clusters[0..num_clusters],
        pairs_list.items,
        num_clusters,
        in_size,
        max_histograms,
        max_num_pairs,
    );

    histogramRemap(
        alphabet_size,
        in,
        in_size,
        clusters[0..num_clusters],
        num_clusters,
        out,
        &tmp,
        histogram_symbols[0..in_size],
    );

    out_size.* = try histogramReindex(allocator, alphabet_size, out, histogram_symbols[0..in_size], in_size);
}

// Block Splitting (SplitByteVector)

inline fn myRand(seed: *u32) u32 {
    seed.* *%= 16807;
    return seed.*;
}

inline fn bitCost(count: usize) f64 {
    return if (count == 0) -2.0 else fast_log.fastLog2(count);
}

fn initialEntropyCodes(
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    length: usize,
    stride: usize,
    num_histograms: usize,
    histograms: []Histogram(alphabet_size),
) void {
    var seed: u32 = 7;
    const block_length = length / num_histograms;
    for (0..num_histograms) |i| {
        histograms[i].clear();
    }
    for (0..num_histograms) |i| {
        var pos = length * i / num_histograms;
        if (i != 0) {
            pos += myRand(&seed) % block_length;
        }
        if (pos + stride >= length) {
            pos = length - stride - 1;
        }
        histograms[i].addVector(data[pos .. pos + stride]);
    }
}

fn refineEntropyCodes(
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    length: usize,
    stride: usize,
    num_histograms: usize,
    histograms: []Histogram(alphabet_size),
    tmp: *Histogram(alphabet_size),
) void {
    var iters = 2 * length / stride + 100;
    var seed: u32 = 7;
    iters = ((iters + num_histograms - 1) / num_histograms) * num_histograms;
    for (0..iters) |iter| {
        tmp.clear();
        var pos: usize = 0;
        const actual_stride = if (stride >= length) length else stride;
        if (actual_stride < length) {
            pos = myRand(&seed) % (length - actual_stride + 1);
        }
        tmp.addVector(data[pos .. pos + actual_stride]);
        histograms[iter % num_histograms].addHistogram(tmp);
    }
}

fn findBlocks(
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    length: usize,
    block_switch_bitcost: f64,
    num_histograms: usize,
    histograms: []const Histogram(alphabet_size),
    insert_cost: []f64,
    cost: []f64,
    switch_signal: []u8,
    block_id: []u8,
) usize {
    const bitmap_len = (num_histograms + 7) >> 3;
    var num_blocks: usize = 1;

    if (num_histograms <= 1) {
        @memset(block_id[0..length], 0);
        return 1;
    }

    for (0..num_histograms) |i| {
        insert_cost[i] = fast_log.fastLog2(histograms[i].total_count_);
    }
    var sym = alphabet_size;
    while (sym != 0) {
        sym -= 1;
        for (0..num_histograms) |j| {
            insert_cost[sym * num_histograms + j] = insert_cost[j] - bitCost(histograms[j].data_[sym]);
        }
    }

    @memset(cost[0..num_histograms], 0);
    @memset(switch_signal[0 .. length * bitmap_len], 0);

    const prologue_length: usize = 2000;
    const multiplier: f64 = 0.07 / 2000.0;

    for (0..length) |byte_ix| {
        const ix = byte_ix * bitmap_len;
        const symbol: usize = data[byte_ix];
        const insert_cost_ix = symbol * num_histograms;
        var min_cost: f64 = 1e99;
        var block_switch_cost = block_switch_bitcost;

        for (0..num_histograms) |k| {
            cost[k] += insert_cost[insert_cost_ix + k];
            if (cost[k] < min_cost) {
                min_cost = cost[k];
                block_id[byte_ix] = @intCast(k);
            }
        }
        if (byte_ix < prologue_length) {
            block_switch_cost *= 0.77 + multiplier * @as(f64, @floatFromInt(byte_ix));
        }
        for (0..num_histograms) |k| {
            cost[k] -= min_cost;
            if (cost[k] >= block_switch_cost) {
                const mask = @as(u8, 1) << @intCast(k & 7);
                cost[k] = block_switch_cost;
                switch_signal[ix + (k >> 3)] |= mask;
            }
        }
    }

    var byte_ix = length - 1;
    var ix = byte_ix * bitmap_len;
    var cur_id = block_id[byte_ix];
    while (byte_ix > 0) {
        const mask = @as(u8, 1) << @intCast(cur_id & 7);
        byte_ix -= 1;
        ix -= bitmap_len;
        if ((switch_signal[ix + (cur_id >> 3)] & mask) != 0) {
            if (cur_id != block_id[byte_ix]) {
                cur_id = block_id[byte_ix];
                num_blocks += 1;
            }
        }
        block_id[byte_ix] = cur_id;
    }
    return num_blocks;
}

fn remapBlockIds(
    block_ids: []u8,
    length: usize,
    new_id: []u16,
    num_histograms: usize,
) usize {
    const kInvalidId: u16 = 256;
    var next_id: u16 = 0;
    @memset(new_id[0..num_histograms], kInvalidId);

    for (0..length) |i| {
        if (new_id[block_ids[i]] == kInvalidId) {
            new_id[block_ids[i]] = next_id;
            next_id += 1;
        }
    }
    for (0..length) |i| {
        block_ids[i] = @intCast(new_id[block_ids[i]]);
    }
    return next_id;
}

fn buildBlockHistograms(
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    length: usize,
    block_ids: []const u8,
    num_histograms: usize,
    histograms: []Histogram(alphabet_size),
) void {
    for (0..num_histograms) |i| {
        histograms[i].clear();
    }
    for (0..length) |i| {
        histograms[block_ids[i]].add(data[i]);
    }
}

fn clusterBlocks(
    allocator: std.mem.Allocator,
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    length: usize,
    num_blocks: usize,
    block_ids: []const u8,
    split: *BlockSplit,
) !void {
    const HISTOGRAMS_PER_BATCH: usize = 64;
    const CLUSTERS_PER_BATCH: usize = 16;
    const expected_num_clusters = CLUSTERS_PER_BATCH * (num_blocks + HISTOGRAMS_PER_BATCH - 1) / HISTOGRAMS_PER_BATCH;

    var all_histograms_list = try std.ArrayList(Histogram(alphabet_size)).initCapacity(allocator, expected_num_clusters);
    defer all_histograms_list.deinit(allocator);

    var cluster_size_list = try std.ArrayList(u32).initCapacity(allocator, expected_num_clusters);
    defer cluster_size_list.deinit(allocator);

    const histogram_symbols = try allocator.alloc(u32, num_blocks);
    defer allocator.free(histogram_symbols);

    const block_lengths = try allocator.alloc(u32, num_blocks);
    defer allocator.free(block_lengths);

    {
        var block_idx: usize = 0;
        var cur_length: u32 = 0;
        for (0..length) |i| {
            cur_length += 1;
            if (i + 1 == length or block_ids[i] != block_ids[i + 1]) {
                block_lengths[block_idx] = cur_length;
                cur_length = 0;
                block_idx += 1;
            }
        }
    }

    const histograms = try allocator.alloc(Histogram(alphabet_size), @min(num_blocks, HISTOGRAMS_PER_BATCH));
    defer allocator.free(histograms);

    const max_num_pairs = HISTOGRAMS_PER_BATCH * HISTOGRAMS_PER_BATCH / 2;
    var pairs_list = try std.ArrayList(HistogramPair).initCapacity(allocator, max_num_pairs + 1);
    defer pairs_list.deinit(allocator);
    pairs_list.appendNTimesAssumeCapacity(HistogramPair{}, max_num_pairs + 1);

    var tmp = [2]Histogram(alphabet_size){ undefined, undefined };
    var pos: usize = 0;
    var num_clusters: usize = 0;

    var i: usize = 0;
    while (i < num_blocks) : (i += HISTOGRAMS_PER_BATCH) {
        const num_to_combine = @min(num_blocks - i, HISTOGRAMS_PER_BATCH);
        for (0..num_to_combine) |j| {
            histograms[j].clear();
            histograms[j].addVector(data[pos .. pos + block_lengths[i + j]]);
            histograms[j].bit_cost_ = brotliPopulationCost(alphabet_size, &histograms[j]);
            pos += block_lengths[i + j];
        }

        var sizes: [HISTOGRAMS_PER_BATCH]u32 = @splat(1);
        var new_clusters: [HISTOGRAMS_PER_BATCH]u32 = undefined;
        var symbols: [HISTOGRAMS_PER_BATCH]u32 = undefined;
        var remap: [HISTOGRAMS_PER_BATCH]u32 = undefined;
        for (0..num_to_combine) |j| {
            new_clusters[j] = @intCast(j);
            symbols[j] = @intCast(j);
        }

        const num_new_clusters = histogramCombine(
            alphabet_size,
            histograms[0..num_to_combine],
            &tmp[0],
            &sizes,
            symbols[0..num_to_combine],
            new_clusters[0..num_to_combine],
            pairs_list.items,
            num_to_combine,
            num_to_combine,
            CLUSTERS_PER_BATCH,
            max_num_pairs,
        );

        histogramRemap(
            alphabet_size,
            histograms[0..num_to_combine],
            num_to_combine,
            new_clusters[0..num_new_clusters],
            num_new_clusters,
            histograms[0..num_to_combine],
            &tmp[0],
            symbols[0..num_to_combine],
        );

        for (0..num_new_clusters) |j| {
            remap[new_clusters[j]] = @intCast(j);
        }
        for (0..num_to_combine) |j| {
            histogram_symbols[i + j] = @intCast(num_clusters + remap[symbols[j]]);
        }
        for (0..num_new_clusters) |j| {
            try all_histograms_list.append(allocator, histograms[new_clusters[j]]);
            try cluster_size_list.append(allocator, sizes[new_clusters[j]]);
        }
        num_clusters += num_new_clusters;
    }

    const clusters = try allocator.alloc(u32, num_clusters);
    defer allocator.free(clusters);
    for (0..num_clusters) |j| clusters[j] = @intCast(j);

    const max_num_pairs2 = @min(64 * num_clusters, (num_clusters / 2) * num_clusters);
    if (pairs_list.items.len < max_num_pairs2 + 1) {
        try pairs_list.resize(allocator, max_num_pairs2 + 1);
    }

    const num_final_clusters = histogramCombine(
        alphabet_size,
        all_histograms_list.items,
        &tmp[0],
        cluster_size_list.items,
        histogram_symbols[0..num_blocks],
        clusters,
        pairs_list.items,
        num_clusters,
        num_blocks,
        CLUSTERS_PER_BATCH,
        max_num_pairs2,
    );

    const new_index = try allocator.alloc(u32, num_clusters);
    defer allocator.free(new_index);
    @memset(new_index, std.math.maxInt(u32));

    var next_index: u32 = 0;
    pos = 0;
    var block_idx: usize = 0;
    while (block_idx < num_blocks) : (block_idx += HISTOGRAMS_PER_BATCH) {
        const num_to_combine = @min(num_blocks - block_idx, HISTOGRAMS_PER_BATCH);
        for (0..num_to_combine) |i_c| {
            tmp[0].clear();
            tmp[0].addVector(data[pos .. pos + block_lengths[block_idx + i_c]]);
            pos += block_lengths[block_idx + i_c];
            var best_out: u32 = if (i_c == 0) histogram_symbols[block_idx] else histogram_symbols[block_idx + i_c - 1];
            var best_bits = histogramBitCostDistance(alphabet_size, &tmp[0], &all_histograms_list.items[best_out], &tmp[1]);
            for (0..num_final_clusters) |j| {
                const cur_bits = histogramBitCostDistance(alphabet_size, &tmp[0], &all_histograms_list.items[clusters[j]], &tmp[1]);
                if (cur_bits < best_bits) {
                    best_bits = cur_bits;
                    best_out = clusters[j];
                }
            }
            histogram_symbols[block_idx + i_c] = best_out;
            if (new_index[best_out] == std.math.maxInt(u32)) {
                new_index[best_out] = next_index;
                next_index += 1;
            }
        }
    }

    try split.types.ensureTotalCapacity(allocator, num_blocks);
    try split.lengths.ensureTotalCapacity(allocator, num_blocks);
    split.clearRetainingCapacity();

    var cur_len: u32 = 0;
    var max_type: u8 = 0;
    for (0..num_blocks) |j| {
        cur_len += block_lengths[j];
        if (j + 1 == num_blocks or histogram_symbols[j] != histogram_symbols[j + 1]) {
            const id: u8 = @intCast(new_index[histogram_symbols[j]]);
            try split.types.append(allocator, id);
            try split.lengths.append(allocator, cur_len);
            max_type = @max(max_type, id);
            cur_len = 0;
        }
    }
    split.num_blocks = split.types.items.len;
    split.num_types = @as(usize, max_type) + 1;
}

pub fn splitByteVector(
    allocator: std.mem.Allocator,
    comptime DataType: type,
    comptime alphabet_size: usize,
    data: []const DataType,
    symbols_per_histogram: usize,
    max_histograms_in: usize,
    sampling_stride_length: usize,
    block_switch_cost: f64,
    quality: u32,
    split: *BlockSplit,
) !void {
    if (data.len == 0) {
        split.num_types = 1;
        split.num_blocks = 0;
        return;
    }
    if (data.len < 128) {
        split.clearRetainingCapacity();
        split.num_types = 1;
        try split.types.append(allocator, 0);
        try split.lengths.append(allocator, @intCast(data.len));
        split.num_blocks = 1;
        return;
    }

    var num_histograms = @min(max_histograms_in, data.len / symbols_per_histogram + 1);

    const histograms = try allocator.alloc(Histogram(alphabet_size), num_histograms + 1);
    defer allocator.free(histograms);

    initialEntropyCodes(
        DataType,
        alphabet_size,
        data,
        data.len,
        sampling_stride_length,
        num_histograms,
        histograms,
    );
    refineEntropyCodes(
        DataType,
        alphabet_size,
        data,
        data.len,
        sampling_stride_length,
        num_histograms,
        histograms,
        &histograms[num_histograms],
    );

    const block_ids = try allocator.alloc(u8, data.len);
    defer allocator.free(block_ids);

    const bitmaplen = (num_histograms + 7) >> 3;
    const insert_cost = try allocator.alloc(f64, alphabet_size * num_histograms);
    defer allocator.free(insert_cost);

    const cost = try allocator.alloc(f64, num_histograms);
    defer allocator.free(cost);

    const switch_signal = try allocator.alloc(u8, data.len * bitmaplen);
    defer allocator.free(switch_signal);

    const new_id = try allocator.alloc(u16, num_histograms);
    defer allocator.free(new_id);

    const iters: usize = if (quality < 11) 3 else 10;
    var num_blocks: usize = 0;

    for (0..iters) |_| {
        num_blocks = findBlocks(
            DataType,
            alphabet_size,
            data,
            data.len,
            block_switch_cost,
            num_histograms,
            histograms[0..num_histograms],
            insert_cost,
            cost,
            switch_signal,
            block_ids,
        );
        num_histograms = remapBlockIds(block_ids, data.len, new_id, num_histograms);
        buildBlockHistograms(
            DataType,
            alphabet_size,
            data,
            data.len,
            block_ids,
            num_histograms,
            histograms[0..num_histograms],
        );
    }

    try clusterBlocks(
        allocator,
        DataType,
        alphabet_size,
        data,
        data.len,
        num_blocks,
        block_ids,
        split,
    );
}

pub fn splitBlock(
    allocator: std.mem.Allocator,
    cmds: []const Command,
    data: []const u8,
    pos: usize,
    mask: usize,
    quality: u32,
    literal_split: *BlockSplit,
    command_split: *BlockSplit,
    distance_split: *BlockSplit,
) !void {
    // 1. Literals
    var literals_count: usize = 0;
    for (cmds) |cmd| literals_count += cmd.insert_len_;
    const literals = try allocator.alloc(u8, literals_count);
    defer allocator.free(literals);

    var l_pos: usize = 0;
    var from_pos = pos & mask;
    for (cmds) |cmd| {
        var insert_len = cmd.insert_len_;
        if (from_pos + insert_len > mask) {
            const head_size = mask + 1 - from_pos;
            @memcpy(literals[l_pos .. l_pos + head_size], data[from_pos .. from_pos + head_size]);
            from_pos = 0;
            l_pos += head_size;
            insert_len -= @intCast(head_size);
        }
        if (insert_len > 0) {
            @memcpy(literals[l_pos .. l_pos + insert_len], data[from_pos .. from_pos + insert_len]);
            l_pos += insert_len;
        }
        from_pos = (from_pos + insert_len + cmd.copyLen()) & mask;
    }

    try splitByteVector(
        allocator,
        u8,
        256,
        literals,
        544,
        100,
        70,
        28.1,
        quality,
        literal_split,
    );

    // 2. Commands
    const cmd_codes = try allocator.alloc(u16, cmds.len);
    defer allocator.free(cmd_codes);
    for (cmds, 0..) |cmd, i| {
        cmd_codes[i] = cmd.cmd_prefix_;
    }

    try splitByteVector(
        allocator,
        u16,
        704,
        cmd_codes,
        530,
        50,
        40,
        13.5,
        quality,
        command_split,
    );

    // 3. Distances
    var dist_count: usize = 0;
    for (cmds) |cmd| {
        if (cmd.copyLen() > 0 and cmd.cmd_prefix_ >= 128) dist_count += 1;
    }
    const dist_codes = try allocator.alloc(u16, dist_count);
    defer allocator.free(dist_codes);
    var d_idx: usize = 0;
    for (cmds) |cmd| {
        if (cmd.copyLen() > 0 and cmd.cmd_prefix_ >= 128) {
            dist_codes[d_idx] = cmd.dist_prefix_ & 0x3FF;
            d_idx += 1;
        }
    }

    try splitByteVector(
        allocator,
        u16,
        544,
        dist_codes,
        544,
        50,
        40,
        14.6,
        quality,
        distance_split,
    );
}

// Distance Cost and Parameter Tuning

pub inline fn commandRestoreDistanceCode(
    cmd: *const Command,
    dist_direct: usize,
    dist_postfix: usize,
) u32 {
    const dcode = cmd.dist_prefix_ & 0x3FF;
    if (dcode < 16 + dist_direct) {
        return dcode;
    } else {
        const nbits = cmd.dist_prefix_ >> 10;
        const extra = cmd.dist_extra_;
        const postfix_mask = (@as(u32, 1) << @intCast(dist_postfix)) - 1;
        const hcode = (dcode - @as(u32, @intCast(dist_direct)) - 16) >> @intCast(dist_postfix);
        const lcode = (dcode - @as(u32, @intCast(dist_direct)) - 16) & postfix_mask;
        const offset = ((2 + (hcode & 1)) << @intCast(nbits)) - 4;
        return ((offset + extra) << @intCast(dist_postfix)) + lcode + @as(u32, @intCast(dist_direct)) + 16;
    }
}

pub fn computeDistanceCost(
    cmds: []const Command,
    orig_direct: usize,
    orig_postfix: usize,
    new_direct: usize,
    new_postfix: usize,
    max_distance: usize,
    cost: *f64,
    tmp: *HistogramDistance,
) bool {
    const equal_params = (orig_direct == new_direct and orig_postfix == new_postfix);
    var extra_bits: f64 = 0.0;
    tmp.clear();

    for (cmds) |cmd| {
        if (cmd.copyLen() > 0 and cmd.cmd_prefix_ >= 128) {
            var dist_prefix: u16 = undefined;
            var dist_extra: u32 = undefined;
            if (equal_params) {
                dist_prefix = cmd.dist_prefix_;
            } else {
                const distance = commandRestoreDistanceCode(&cmd, orig_direct, orig_postfix);
                if (distance > max_distance) return false;
                hlmq.prefixEncodeCopyDistance(
                    distance,
                    new_direct,
                    new_postfix,
                    &dist_prefix,
                    &dist_extra,
                );
            }
            tmp.add(dist_prefix & 0x3FF);
            extra_bits += @floatFromInt(dist_prefix >> 10);
        }
    }

    cost.* = brotliPopulationCost(544, tmp) + extra_bits;
    return true;
}

pub fn recomputeDistancePrefixes(
    cmds: []Command,
    orig_direct: usize,
    orig_postfix: usize,
    new_direct: usize,
    new_postfix: usize,
) void {
    if (orig_direct == new_direct and orig_postfix == new_postfix) return;
    for (cmds) |*cmd| {
        if (cmd.copyLen() > 0 and cmd.cmd_prefix_ >= 128) {
            const distance = commandRestoreDistanceCode(cmd, orig_direct, orig_postfix);
            hlmq.prefixEncodeCopyDistance(
                distance,
                new_direct,
                new_postfix,
                &cmd.dist_prefix_,
                &cmd.dist_extra_,
            );
        }
    }
}

pub inline fn commandDistanceContext(cmd: *const Command) usize {
    const r = cmd.cmd_prefix_ >> 6;
    const c = cmd.cmd_prefix_ & 7;
    if ((r == 0 or r == 2 or r == 4 or r == 7) and (c <= 2)) {
        return c;
    }
    return 3;
}

pub const MetaBlockHQ = struct {
    literal_split: BlockSplit = .{},
    command_split: BlockSplit = .{},
    distance_split: BlockSplit = .{},

    literal_histograms: []HistogramLiteral = &.{},
    command_histograms: []HistogramCommand = &.{},
    distance_histograms: []HistogramDistance = &.{},

    literal_context_map: []u32 = &.{},
    distance_context_map: []u32 = &.{},

    num_literal_histograms: usize = 0,
    num_distance_histograms: usize = 0,

    pub fn deinit(self: *MetaBlockHQ, allocator: std.mem.Allocator) void {
        self.literal_split.deinit(allocator);
        self.command_split.deinit(allocator);
        self.distance_split.deinit(allocator);
        allocator.free(self.literal_histograms);
        allocator.free(self.command_histograms);
        allocator.free(self.distance_histograms);
        allocator.free(self.literal_context_map);
        allocator.free(self.distance_context_map);
    }
};

pub fn buildMetaBlockHQ(
    allocator: std.mem.Allocator,
    ringbuffer: []const u8,
    pos: usize,
    mask: usize,
    quality: u32,
    cmds: []Command,
    num_direct_codes: *usize,
    distance_postfix_bits: *usize,
    alphabet_size_limit: *u32,
    max_distance: usize,
    literal_context_mode: context_mod.ContextType,
    mb: *MetaBlockHQ,
) !void {
    // 1. Distance parameter optimization
    const orig_direct = num_direct_codes.*;
    const orig_postfix = distance_postfix_bits.*;
    var best_direct = orig_direct;
    var best_postfix = orig_postfix;
    var best_dist_cost: f64 = 1e99;
    var tmp_dist: HistogramDistance = undefined;

    var ndirect_msb: usize = 0;
    var check_orig: bool = true;
    var npostfix: usize = 0;
    while (npostfix <= 3) : (npostfix += 1) {
        while (ndirect_msb < 16) : (ndirect_msb += 1) {
            const ndirect = ndirect_msb << @intCast(npostfix);
            if (npostfix == orig_postfix and ndirect == orig_direct) {
                check_orig = false;
            }
            var dist_cost: f64 = undefined;
            const skip = !computeDistanceCost(
                cmds,
                orig_direct,
                orig_postfix,
                ndirect,
                npostfix,
                max_distance,
                &dist_cost,
                &tmp_dist,
            );
            if (skip or dist_cost > best_dist_cost) {
                break;
            }
            best_dist_cost = dist_cost;
            best_direct = ndirect;
            best_postfix = npostfix;
        }
        if (ndirect_msb > 0) ndirect_msb -= 1;
        ndirect_msb /= 2;
    }
    if (check_orig) {
        var dist_cost: f64 = undefined;
        _ = computeDistanceCost(cmds, orig_direct, orig_postfix, orig_direct, orig_postfix, max_distance, &dist_cost, &tmp_dist);
        if (dist_cost < best_dist_cost) {
            best_direct = orig_direct;
            best_postfix = orig_postfix;
        }
    }

    num_direct_codes.* = best_direct;
    distance_postfix_bits.* = best_postfix;
    alphabet_size_limit.* = constants.distanceAlphabetSize(@intCast(best_postfix), @intCast(best_direct), constants.MAX_DISTANCE_BITS);
    recomputeDistancePrefixes(cmds, orig_direct, orig_postfix, best_direct, best_postfix);

    // 2. Block splitting
    try splitBlock(
        allocator,
        cmds,
        ringbuffer,
        pos,
        mask,
        quality,
        &mb.literal_split,
        &mb.command_split,
        &mb.distance_split,
    );

    // 3. Build histograms with context
    const literal_histograms_size = mb.literal_split.num_types << 6;
    const raw_literal_histograms = try allocator.alloc(HistogramLiteral, literal_histograms_size);
    defer allocator.free(raw_literal_histograms);
    for (raw_literal_histograms) |*h| h.clear();

    mb.command_histograms = try allocator.alloc(HistogramCommand, mb.command_split.num_types);
    for (mb.command_histograms) |*h| h.clear();

    const distance_histograms_size = mb.distance_split.num_types << 2;
    const raw_distance_histograms = try allocator.alloc(HistogramDistance, distance_histograms_size);
    defer allocator.free(raw_distance_histograms);
    for (raw_distance_histograms) |*h| h.clear();

    {
        var cur_pos = pos;
        var prev_byte: u8 = if (pos > 0) ringbuffer[(pos - 1) & mask] else 0;
        var prev_byte2: u8 = if (pos > 1) ringbuffer[(pos - 2) & mask] else 0;

        var lit_block_idx: usize = 0;
        var lit_block_rem = if (mb.literal_split.num_blocks > 0) mb.literal_split.lengths.items[0] else 0;
        var cmd_block_idx: usize = 0;
        var cmd_block_rem = if (mb.command_split.num_blocks > 0) mb.command_split.lengths.items[0] else 0;
        var dist_block_idx: usize = 0;
        var dist_block_rem = if (mb.distance_split.num_blocks > 0) mb.distance_split.lengths.items[0] else 0;

        for (cmds) |cmd| {
            if (cmd_block_rem == 0 and cmd_block_idx + 1 < mb.command_split.num_blocks) {
                cmd_block_idx += 1;
                cmd_block_rem = mb.command_split.lengths.items[cmd_block_idx];
            }
            cmd_block_rem -= 1;
            const cmd_type = mb.command_split.types.items[cmd_block_idx];
            mb.command_histograms[cmd_type].add(cmd.cmd_prefix_);

            var j = cmd.insert_len_;
            while (j != 0) : (j -= 1) {
                if (lit_block_rem == 0 and lit_block_idx + 1 < mb.literal_split.num_blocks) {
                    lit_block_idx += 1;
                    lit_block_rem = mb.literal_split.lengths.items[lit_block_idx];
                }
                lit_block_rem -= 1;
                const lit_type = mb.literal_split.types.items[lit_block_idx];
                const literal = ringbuffer[cur_pos & mask];
                const ctx = context_mod.contextId(prev_byte, prev_byte2, literal_context_mode);
                raw_literal_histograms[(lit_type << 6) + ctx].add(literal);
                prev_byte2 = prev_byte;
                prev_byte = literal;
                cur_pos += 1;
            }
            cur_pos += cmd.copyLen();
            if (cmd.copyLen() > 0) {
                prev_byte2 = ringbuffer[(cur_pos - 2) & mask];
                prev_byte = ringbuffer[(cur_pos - 1) & mask];
                if (cmd.cmd_prefix_ >= 128) {
                    if (dist_block_rem == 0 and dist_block_idx + 1 < mb.distance_split.num_blocks) {
                        dist_block_idx += 1;
                        dist_block_rem = mb.distance_split.lengths.items[dist_block_idx];
                    }
                    dist_block_rem -= 1;
                    const dist_type = mb.distance_split.types.items[dist_block_idx];
                    const dist_ctx = commandDistanceContext(&cmd);
                    raw_distance_histograms[(dist_type << 2) + dist_ctx].add(cmd.dist_prefix_ & 0x3FF);
                }
            }
        }
    }

    // 4. Cluster literal histograms
    mb.literal_context_map = try allocator.alloc(u32, literal_histograms_size);
    mb.literal_histograms = try allocator.alloc(HistogramLiteral, literal_histograms_size);
    try clusterHistograms(
        allocator,
        256,
        raw_literal_histograms,
        literal_histograms_size,
        256,
        mb.literal_histograms,
        &mb.num_literal_histograms,
        mb.literal_context_map,
    );

    // 5. Cluster distance histograms
    mb.distance_context_map = try allocator.alloc(u32, distance_histograms_size);
    mb.distance_histograms = try allocator.alloc(HistogramDistance, distance_histograms_size);
    try clusterHistograms(
        allocator,
        544,
        raw_distance_histograms,
        distance_histograms_size,
        256,
        mb.distance_histograms,
        &mb.num_distance_histograms,
        mb.distance_context_map,
    );

    // 6. Optimize histograms for RLE
    for (mb.literal_histograms[0..mb.num_literal_histograms]) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data_);
    }
    for (mb.command_histograms) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data_);
    }
    for (mb.distance_histograms[0..mb.num_distance_histograms]) |*h| {
        huff_enc.optimizeHuffmanCountsForRle(&h.data_);
    }
}

pub fn storeMetaBlockHQ(
    allocator: std.mem.Allocator,
    input: []const u8,
    start_pos: usize,
    length: usize,
    mask: usize,
    is_last: bool,
    num_direct_codes: usize,
    distance_postfix_bits: usize,
    num_distance_symbols: usize,
    literal_context_mode: context_mod.ContextType,
    commands: []const Command,
    mb: *const MetaBlockHQ,
    storage_ix: *usize,
    storage: []u8,
) !void {
    metablock_fast.storeCompressedMetaBlockHeader(is_last, length, storage_ix, storage);

    var tree: [metablock_fast.MAX_HUFFMAN_TREE_SIZE]compress_fragment.HuffmanTree = undefined;

    const lit_depths = try allocator.alloc(u8, mb.num_literal_histograms * 256);
    defer allocator.free(lit_depths);
    const lit_bits = try allocator.alloc(u16, mb.num_literal_histograms * 256);
    defer allocator.free(lit_bits);

    const cmd_depths = try allocator.alloc(u8, mb.command_split.num_types * 704);
    defer allocator.free(cmd_depths);
    const cmd_bits = try allocator.alloc(u16, mb.command_split.num_types * 704);
    defer allocator.free(cmd_bits);

    const dist_depths = try allocator.alloc(u8, mb.num_distance_histograms * 544);
    defer allocator.free(dist_depths);
    const dist_bits = try allocator.alloc(u16, mb.num_distance_histograms * 544);
    defer allocator.free(dist_bits);

    var lit_enc = BlockEncoder.init(
        256,
        mb.literal_split.num_types,
        mb.literal_split.types.items,
        mb.literal_split.lengths.items,
        mb.literal_split.num_blocks,
        lit_depths,
        lit_bits,
    );
    var cmd_enc = BlockEncoder.init(
        704,
        mb.command_split.num_types,
        mb.command_split.types.items,
        mb.command_split.lengths.items,
        mb.command_split.num_blocks,
        cmd_depths,
        cmd_bits,
    );
    var dist_enc = BlockEncoder.init(
        544,
        mb.distance_split.num_types,
        mb.distance_split.types.items,
        mb.distance_split.lengths.items,
        mb.distance_split.num_blocks,
        dist_depths,
        dist_bits,
    );

    lit_enc.buildAndStoreBlockSwitchEntropyCodes(&tree, storage_ix, storage);
    cmd_enc.buildAndStoreBlockSwitchEntropyCodes(&tree, storage_ix, storage);
    dist_enc.buildAndStoreBlockSwitchEntropyCodes(&tree, storage_ix, storage);

    // Distance params
    bit_writer.writeBits(2, distance_postfix_bits, storage_ix, storage);
    bit_writer.writeBits(4, num_direct_codes >> @intCast(distance_postfix_bits), storage_ix, storage);

    // Context mode: for each literal block type
    for (0..mb.literal_split.num_types) |_| {
        bit_writer.writeBits(2, @backingInt(literal_context_mode), storage_ix, storage);
    }

    // Literal context map
    try encodeContextMap(allocator, mb.literal_context_map, mb.num_literal_histograms, &tree, storage_ix, storage);

    // Distance context map
    try encodeContextMap(allocator, mb.distance_context_map, mb.num_distance_histograms, &tree, storage_ix, storage);

    // Huffman trees
    for (0..mb.num_literal_histograms) |i| {
        const ix = i * 256;
        metablock_fast.buildAndStoreHuffmanTree(
            &mb.literal_histograms[i].data_,
            256,
            256,
            &tree,
            lit_depths[ix .. ix + 256],
            lit_bits[ix .. ix + 256],
            storage_ix,
            storage,
        );
    }
    for (0..mb.command_split.num_types) |i| {
        const ix = i * 704;
        metablock_fast.buildAndStoreHuffmanTree(
            &mb.command_histograms[i].data_,
            704,
            704,
            &tree,
            cmd_depths[ix .. ix + 704],
            cmd_bits[ix .. ix + 704],
            storage_ix,
            storage,
        );
    }
    for (0..mb.num_distance_histograms) |i| {
        const ix = i * 544;
        metablock_fast.buildAndStoreHuffmanTree(
            &mb.distance_histograms[i].data_,
            544,
            num_distance_symbols,
            &tree,
            dist_depths[ix .. ix + 544],
            dist_bits[ix .. ix + 544],
            storage_ix,
            storage,
        );
    }

    // Emit commands, literals, and distances
    var cur_pos = start_pos;
    var prev_byte: u8 = if (start_pos > 0) input[(start_pos - 1) & mask] else 0;
    var prev_byte2: u8 = if (start_pos > 1) input[(start_pos - 2) & mask] else 0;

    for (commands) |cmd| {
        cmd_enc.storeSymbol(cmd.cmd_prefix_, storage_ix, storage);
        hlmq.storeCommandExtra(&cmd, storage_ix, storage);
        var j = cmd.insert_len_;
        while (j != 0) : (j -= 1) {
            const lit = input[cur_pos & mask];
            const ctx = context_mod.contextId(prev_byte, prev_byte2, literal_context_mode);
            lit_enc.storeSymbolWithContext(lit, ctx, mb.literal_context_map, storage_ix, storage, 6);
            prev_byte2 = prev_byte;
            prev_byte = lit;
            cur_pos += 1;
        }
        cur_pos += cmd.copyLen();
        if (cmd.copyLen() > 0) {
            prev_byte2 = input[(cur_pos - 2) & mask];
            prev_byte = input[(cur_pos - 1) & mask];
            if (cmd.cmd_prefix_ >= 128) {
                const dist_ctx = commandDistanceContext(&cmd);
                dist_enc.storeSymbolWithContext(cmd.dist_prefix_ & 0x3FF, dist_ctx, mb.distance_context_map, storage_ix, storage, 2);
                bit_writer.writeBits(@intCast(cmd.dist_prefix_ >> 10), cmd.dist_extra_, storage_ix, storage);
            }
        }
    }

    if (is_last) {
        bit_writer.jumpToByteBoundary(storage_ix, storage);
    }
}
