//! Fast one-pass fragment compression (Quality 0).
//!
//! Emits single-pass compressed metablocks with prefix-encoded entropy commands.

const std = @import("std");
const bit_writer = @import("../bitstream/bit_writer.zig");
const constants = @import("../common/constants.zig");
const fast_log = @import("fast_log.zig");
const static_entropy = @import("entropy_encode_static.zig");

pub const BROTLI_WINDOW_GAP: usize = 16;
pub const MAX_DISTANCE: isize = (1 << 18) - 16;
pub const kHashMul32: u32 = 0x1E35A7BD;
pub const kFirstBlockSize: usize = 3 << 15;
pub const kMergeBlockSize: usize = 1 << 16;
pub const kInputMarginBytes: usize = 16;
pub const kMinMatchLen: usize = 5;
pub const MIN_RATIO: usize = 980;

pub const HuffmanTree = struct {
    total_count_: u32,
    index_left_: i16,
    index_right_or_value_: i16,
};

pub inline fn initHuffmanTree(self: *HuffmanTree, count: u32, left: i16, right: i16) void {
    self.total_count_ = count;
    self.index_left_ = left;
    self.index_right_or_value_ = right;
}

const kBrotliShellGaps = [_]usize{ 132, 57, 23, 10, 4, 1 };

inline fn sortHuffmanTreeFast(items: []HuffmanTree) void {
    const n = items.len;
    if (n < 13) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const tmp = items[i];
            var k = i;
            var j = i - 1;
            while (tmp.total_count_ < items[j].total_count_) {
                items[k] = items[j];
                k = j;
                if (j == 0) break;
                j -= 1;
            }
            items[k] = tmp;
        }
    } else {
        var g: usize = if (n < 57) 2 else 0;
        while (g < 6) : (g += 1) {
            const gap = kBrotliShellGaps[g];
            var i = gap;
            while (i < n) : (i += 1) {
                var j = i;
                const tmp = items[i];
                while (j >= gap and tmp.total_count_ < items[j - gap].total_count_) : (j -= gap) {
                    items[j] = items[j - gap];
                }
                items[j] = tmp;
            }
        }
    }
}

inline fn sortHuffmanTreeStandard(items: []HuffmanTree) void {
    const n = items.len;
    const cmp = struct {
        inline fn less(v0: *const HuffmanTree, v1: *const HuffmanTree) bool {
            if (v0.total_count_ != v1.total_count_) {
                return v0.total_count_ < v1.total_count_;
            }
            return v0.index_right_or_value_ > v1.index_right_or_value_;
        }
    }.less;

    if (n < 13) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const tmp = items[i];
            var k = i;
            var j = i - 1;
            while (cmp(&tmp, &items[j])) {
                items[k] = items[j];
                k = j;
                if (j == 0) break;
                j -= 1;
            }
            items[k] = tmp;
        }
    } else {
        var g: usize = if (n < 57) 2 else 0;
        while (g < 6) : (g += 1) {
            const gap = kBrotliShellGaps[g];
            var i = gap;
            while (i < n) : (i += 1) {
                var j = i;
                const tmp = items[i];
                while (j >= gap and cmp(&tmp, &items[j - gap])) : (j -= gap) {
                    items[j] = items[j - gap];
                }
                items[j] = tmp;
            }
        }
    }
}

pub fn brotliSetDepth(p0: i32, pool: []HuffmanTree, depth: []u8, max_depth: i32) bool {
    var stack: [16]i32 = undefined;
    var level: i32 = 0;
    var p = p0;
    std.debug.assert(max_depth <= 15);
    stack[0] = -1;
    while (true) {
        if (pool[@intCast(p)].index_left_ >= 0) {
            level += 1;
            if (level > max_depth) return false;
            stack[@intCast(level)] = pool[@intCast(p)].index_right_or_value_;
            p = pool[@intCast(p)].index_left_;
            continue;
        } else {
            depth[@intCast(pool[@intCast(p)].index_right_or_value_)] = @intCast(level);
        }
        while (level >= 0 and stack[@intCast(level)] == -1) level -= 1;
        if (level < 0) return true;
        p = stack[@intCast(level)];
        stack[@intCast(level)] = -1;
    }
}

pub fn brotliConvertBitDepthsToSymbols(depth: []const u8, bits: []u16) void {
    var bl_count: [16]u16 = @splat(0);
    var next_code: [16]u16 = undefined;
    for (depth) |d| {
        bl_count[d] += 1;
    }
    bl_count[0] = 0;
    next_code[0] = 0;
    var code: u32 = 0;
    for (1..16) |i| {
        code = (code + bl_count[i - 1]) << 1;
        next_code[i] = @intCast(code);
    }
    for (depth, 0..) |d, i| {
        if (d != 0) {
            bits[i] = @bitReverse(next_code[d]) >> @as(u4, @intCast(16 - d));
            next_code[d] += 1;
        }
    }
}

pub const kCmdHistoSeed = [128]u32{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 0, 0, 0, 0,
};

pub const kDefaultCommandDepths = [128]u8{
    0,  4,  4,  5,  6,  6,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,
    0,  0,  0,  4,  4,  4,  4,  4,  5,  5,  6,  6,  6,  6,  7,  7,
    7,  7,  10, 10, 10, 10, 10, 10, 0,  4,  4,  5,  5,  5,  6,  6,
    7,  8,  8,  9,  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    5,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    6,  6,  6,  6,  6,  6,  5,  5,  5,  5,  5,  5,  4,  4,  4,  4,
    4,  4,  4,  5,  5,  5,  5,  5,  5,  6,  6,  7,  7,  7,  8,  10,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 0,  0,  0,  0,
};

pub const kDefaultCommandBits = [128]u16{
    0,    0,    8,    9,    3,   35,   7,    71,
    39,   103,  23,   47,   175, 111,  239,  31,
    0,    0,    0,    4,    12,  2,    10,   6,
    13,   29,   11,   43,   27,  59,   87,   55,
    15,   79,   319,  831,  191, 703,  447,  959,
    0,    14,   1,    25,   5,   21,   19,   51,
    119,  159,  95,   223,  479, 991,  63,   575,
    127,  639,  383,  895,  255, 767,  511,  1023,
    14,   0,    0,    0,    0,   0,    0,    0,
    0,    0,    0,    0,    0,   0,    0,    0,
    27,   59,   7,    39,   23,  55,   30,   1,
    17,   9,    25,   5,    0,   8,    4,    12,
    2,    10,   6,    21,   13,  29,   3,    19,
    11,   15,   47,   31,   95,  63,   127,  255,
    767,  2815, 1791, 3839, 511, 2559, 1535, 3583,
    1023, 3071, 2047, 4095, 0,   0,    0,    0,
};

pub const kDefaultCommandCode = [57]u8{
    0xff, 0x77, 0xd5, 0xbf, 0xe7, 0xde, 0xea, 0x9e, 0x51, 0x5d, 0xde, 0xc6,
    0x70, 0x57, 0xbc, 0x58, 0x58, 0x58, 0xd8, 0xd8, 0x58, 0xd5, 0xcb, 0x8c,
    0xea, 0xe0, 0xc3, 0x87, 0x1f, 0x83, 0xc1, 0x60, 0x1c, 0x67, 0xb2, 0xaa,
    0x06, 0x83, 0xc1, 0x60, 0x30, 0x18, 0xcc, 0xa1, 0xce, 0x88, 0x54, 0x94,
    0x46, 0xe1, 0xb0, 0xd0, 0x4e, 0xb2, 0xf7, 0x04, 0x00,
};
pub const kDefaultCommandCodeNumBits: usize = 448;

pub const OnePassArena = struct {
    lit_depth: [256]u8 = @splat(0),
    lit_bits: [256]u16 = @splat(0),
    cmd_depth: [128]u8 = undefined,
    cmd_bits: [128]u16 = undefined,
    cmd_histo: [128]u32 = undefined,
    cmd_code: [512]u8 = undefined,
    cmd_code_numbits: usize = 0,
    tree: [2 * 256 + 1]HuffmanTree = undefined,
    histogram: [256]u32 = undefined,
    tmp_depth: [constants.NUM_COMMAND_SYMBOLS]u8 = undefined,
    tmp_bits: [64]u16 = undefined,

    pub fn init() OnePassArena {
        var arena: OnePassArena = undefined;
        @memset(&arena.lit_depth, 0);
        @memset(&arena.lit_bits, 0);
        arena.cmd_depth = kDefaultCommandDepths;
        arena.cmd_bits = kDefaultCommandBits;
        @memcpy(arena.cmd_code[0..kDefaultCommandCode.len], &kDefaultCommandCode);
        arena.cmd_code_numbits = kDefaultCommandCodeNumBits;
        return arena;
    }
};

inline fn hash(p: []const u8, shift: u6) u32 {
    const val = std.mem.readInt(u64, p[0..8], .little);
    const h = (val << 24) *% @as(u64, kHashMul32);
    return @truncate(h >> shift);
}

inline fn hashBytesAtOffset(v: u64, offset: u6, shift: u6) u32 {
    const h = ((v >> (8 * offset)) << 24) *% @as(u64, kHashMul32);
    return @truncate(h >> shift);
}

inline fn isMatch(p1: []const u8, p2: []const u8) bool {
    return std.mem.readInt(u32, p1[0..4], .little) == std.mem.readInt(u32, p2[0..4], .little) and p1[4] == p2[4];
}

pub inline fn findMatchLengthWithLimit(s1: []const u8, s2: []const u8, limit: usize) usize {
    const lim = @min(limit, @min(s1.len, s2.len));
    var matched: usize = 0;
    while (matched + 8 <= lim) : (matched += 8) {
        const x = std.mem.readInt(u64, s1[matched..][0..8], .little) ^ std.mem.readInt(u64, s2[matched..][0..8], .little);
        if (x != 0) {
            return matched + (@ctz(x) >> 3);
        }
    }
    while (matched < lim and s1[matched] == s2[matched]) : (matched += 1) {}
    return matched;
}

pub fn buildAndStoreHuffmanTreeFast(
    tree: []HuffmanTree,
    histogram: []const u32,
    histogram_total: usize,
    max_bits: usize,
    depth: []u8,
    bits: []u16,
    storage_ix: *usize,
    storage: []u8,
) void {
    var count: usize = 0;
    var symbols = [4]usize{ 0, 0, 0, 0 };
    var length: usize = 0;
    var total = histogram_total;
    while (total != 0) {
        if (histogram[length] != 0) {
            if (count < 4) {
                symbols[count] = length;
            }
            count += 1;
            total -= histogram[length];
        }
        length += 1;
    }

    if (count <= 1) {
        bit_writer.writeBits(4, 1, storage_ix, storage);
        bit_writer.writeBits(@intCast(max_bits), symbols[0], storage_ix, storage);
        depth[symbols[0]] = 0;
        bits[symbols[0]] = 0;
        return;
    }

    @memset(depth[0..length], 0);
    var count_limit: u32 = 1;
    while (true) : (count_limit *%= 2) {
        var node_idx: usize = 0;
        var l = length;
        while (l != 0) {
            l -= 1;
            if (histogram[l] != 0) {
                const cnt = @max(histogram[l], count_limit);
                initHuffmanTree(&tree[node_idx], cnt, -1, @intCast(l));
                node_idx += 1;
            }
        }
        const n = node_idx;
        var sentinel: HuffmanTree = undefined;
        initHuffmanTree(&sentinel, std.math.maxInt(u32), -1, -1);
        sortHuffmanTreeFast(tree[0..n]);
        tree[node_idx] = sentinel;
        node_idx += 1;
        tree[node_idx] = sentinel;
        node_idx += 1;

        var i: usize = 0;
        var j: usize = n + 1;
        var k: usize = n - 1;
        while (k > 0) : (k -= 1) {
            var left: usize = undefined;
            var right: usize = undefined;
            if (tree[i].total_count_ <= tree[j].total_count_) {
                left = i;
                i += 1;
            } else {
                left = j;
                j += 1;
            }
            if (tree[i].total_count_ <= tree[j].total_count_) {
                right = i;
                i += 1;
            } else {
                right = j;
                j += 1;
            }
            tree[node_idx - 1].total_count_ = tree[left].total_count_ + tree[right].total_count_;
            tree[node_idx - 1].index_left_ = @intCast(left);
            tree[node_idx - 1].index_right_or_value_ = @intCast(right);
            tree[node_idx] = sentinel;
            node_idx += 1;
        }
        if (brotliSetDepth(@intCast(2 * n - 1), tree, depth, 14)) {
            break;
        }
    }

    brotliConvertBitDepthsToSymbols(depth[0..length], bits[0..length]);
    if (count <= 4) {
        bit_writer.writeBits(2, 1, storage_ix, storage);
        bit_writer.writeBits(2, count - 1, storage_ix, storage);

        // Sort symbols by depth
        for (0..count) |si| {
            for (si + 1..count) |sj| {
                if (depth[symbols[sj]] < depth[symbols[si]]) {
                    const tmp = symbols[si];
                    symbols[si] = symbols[sj];
                    symbols[sj] = tmp;
                }
            }
        }

        if (count == 2) {
            bit_writer.writeBits(@intCast(max_bits), symbols[0], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[1], storage_ix, storage);
        } else if (count == 3) {
            bit_writer.writeBits(@intCast(max_bits), symbols[0], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[1], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[2], storage_ix, storage);
        } else {
            bit_writer.writeBits(@intCast(max_bits), symbols[0], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[1], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[2], storage_ix, storage);
            bit_writer.writeBits(@intCast(max_bits), symbols[3], storage_ix, storage);
            bit_writer.writeBits(1, if (depth[symbols[0]] == 1) 1 else 0, storage_ix, storage);
        }
    } else {
        static_entropy.storeStaticCodeLengthCode(storage_ix, storage);
        var previous_value: u8 = 8;
        var idx: usize = 0;
        while (idx < length) {
            const value = depth[idx];
            var reps: usize = 1;
            while (idx + reps < length and depth[idx + reps] == value) : (reps += 1) {}
            idx += reps;
            if (value == 0) {
                bit_writer.writeBits(@intCast(static_entropy.kZeroRepsDepth[reps]), static_entropy.kZeroRepsBits[reps], storage_ix, storage);
            } else {
                if (previous_value != value) {
                    bit_writer.writeBits(@intCast(static_entropy.kCodeLengthDepth[value]), static_entropy.kCodeLengthBits[value], storage_ix, storage);
                    reps -= 1;
                }
                if (reps < 3) {
                    while (reps != 0) : (reps -= 1) {
                        bit_writer.writeBits(@intCast(static_entropy.kCodeLengthDepth[value]), static_entropy.kCodeLengthBits[value], storage_ix, storage);
                    }
                } else {
                    reps -= 3;
                    bit_writer.writeBits(@intCast(static_entropy.kNonZeroRepsDepth[reps]), static_entropy.kNonZeroRepsBits[reps], storage_ix, storage);
                }
                previous_value = value;
            }
        }
    }
}

pub fn brotliCreateHuffmanTree(
    data: []const u32,
    tree_limit: i32,
    tree: []HuffmanTree,
    depth: []u8,
) void {
    const length = data.len;
    var count_limit: u32 = 1;
    var sentinel: HuffmanTree = undefined;
    initHuffmanTree(&sentinel, std.math.maxInt(u32), -1, -1);
    while (true) : (count_limit *%= 2) {
        var n: usize = 0;
        var i = length;
        while (i != 0) {
            i -= 1;
            if (data[i] != 0) {
                const count = @max(data[i], count_limit);
                initHuffmanTree(&tree[n], count, -1, @intCast(i));
                n += 1;
            }
        }

        if (n == 1) {
            depth[@intCast(tree[0].index_right_or_value_)] = 1;
            break;
        }

        sortHuffmanTreeStandard(tree[0..n]);

        tree[n] = sentinel;
        tree[n + 1] = sentinel;

        var idx_i: usize = 0;
        var idx_j: usize = n + 1;
        var k = n - 1;
        while (k > 0) : (k -= 1) {
            var left: usize = undefined;
            var right: usize = undefined;
            if (tree[idx_i].total_count_ <= tree[idx_j].total_count_) {
                left = idx_i;
                idx_i += 1;
            } else {
                left = idx_j;
                idx_j += 1;
            }
            if (tree[idx_i].total_count_ <= tree[idx_j].total_count_) {
                right = idx_i;
                idx_i += 1;
            } else {
                right = idx_j;
                idx_j += 1;
            }
            const j_end = 2 * n - k;
            tree[j_end].total_count_ = tree[left].total_count_ + tree[right].total_count_;
            tree[j_end].index_left_ = @intCast(left);
            tree[j_end].index_right_or_value_ = @intCast(right);
            tree[j_end + 1] = sentinel;
        }
        if (brotliSetDepth(@intCast(2 * n - 1), tree, depth, tree_limit)) {
            break;
        }
    }
}

fn reverseSlice(v: []u8, start: usize, end: usize) void {
    if (start >= end) return;
    var s = start;
    var e = end - 1;
    while (s < e) {
        const tmp = v[s];
        v[s] = v[e];
        v[e] = tmp;
        s += 1;
        e -= 1;
    }
}

fn brotliWriteHuffmanTreeRepetitions(
    previous_value: u8,
    value: u8,
    repetitions_in: usize,
    tree_size: *usize,
    tree: []u8,
    extra_bits_data: []u8,
) void {
    var repetitions = repetitions_in;
    if (previous_value != value) {
        tree[tree_size.*] = value;
        extra_bits_data[tree_size.*] = 0;
        tree_size.* += 1;
        repetitions -= 1;
    }
    if (repetitions == 7) {
        tree[tree_size.*] = value;
        extra_bits_data[tree_size.*] = 0;
        tree_size.* += 1;
        repetitions -= 1;
    }
    if (repetitions < 3) {
        for (0..repetitions) |_| {
            tree[tree_size.*] = value;
            extra_bits_data[tree_size.*] = 0;
            tree_size.* += 1;
        }
    } else {
        const start = tree_size.*;
        repetitions -= 3;
        while (true) {
            tree[tree_size.*] = constants.REPEAT_PREVIOUS_CODE_LENGTH;
            extra_bits_data[tree_size.*] = @truncate(repetitions & 0x3);
            tree_size.* += 1;
            repetitions >>= 2;
            if (repetitions == 0) break;
            repetitions -= 1;
        }
        reverseSlice(tree, start, tree_size.*);
        reverseSlice(extra_bits_data, start, tree_size.*);
    }
}

fn brotliWriteHuffmanTreeRepetitionsZeros(
    repetitions_in: usize,
    tree_size: *usize,
    tree: []u8,
    extra_bits_data: []u8,
) void {
    var repetitions = repetitions_in;
    if (repetitions == 11) {
        tree[tree_size.*] = 0;
        extra_bits_data[tree_size.*] = 0;
        tree_size.* += 1;
        repetitions -= 1;
    }
    if (repetitions < 3) {
        for (0..repetitions) |_| {
            tree[tree_size.*] = 0;
            extra_bits_data[tree_size.*] = 0;
            tree_size.* += 1;
        }
    } else {
        const start = tree_size.*;
        repetitions -= 3;
        while (true) {
            tree[tree_size.*] = constants.REPEAT_ZERO_CODE_LENGTH;
            extra_bits_data[tree_size.*] = @truncate(repetitions & 0x7);
            tree_size.* += 1;
            repetitions >>= 3;
            if (repetitions == 0) break;
            repetitions -= 1;
        }
        reverseSlice(tree, start, tree_size.*);
        reverseSlice(extra_bits_data, start, tree_size.*);
    }
}

fn decideOverRleUse(
    depth: []const u8,
    use_rle_for_non_zero: *bool,
    use_rle_for_zero: *bool,
) void {
    var total_reps_zero: usize = 0;
    var total_reps_non_zero: usize = 0;
    var count_reps_zero: usize = 1;
    var count_reps_non_zero: usize = 1;
    var i: usize = 0;
    while (i < depth.len) {
        const value = depth[i];
        var reps: usize = 1;
        while (i + reps < depth.len and depth[i + reps] == value) : (reps += 1) {}
        if (reps >= 3 and value == 0) {
            total_reps_zero += reps;
            count_reps_zero += 1;
        }
        if (reps >= 4 and value != 0) {
            total_reps_non_zero += reps;
            count_reps_non_zero += 1;
        }
        i += reps;
    }
    use_rle_for_non_zero.* = total_reps_non_zero > count_reps_non_zero * 2;
    use_rle_for_zero.* = total_reps_zero > count_reps_zero * 2;
}

pub fn brotliWriteHuffmanTree(
    depth: []const u8,
    tree_size: *usize,
    tree: []u8,
    extra_bits_data: []u8,
) void {
    var previous_value: u8 = constants.INITIAL_REPEATED_CODE_LENGTH;
    var use_rle_for_non_zero = false;
    var use_rle_for_zero = false;

    // Throw away trailing zeros
    var new_length = depth.len;
    while (new_length > 0 and depth[new_length - 1] == 0) : (new_length -= 1) {}

    if (depth.len > 50) {
        decideOverRleUse(depth[0..new_length], &use_rle_for_non_zero, &use_rle_for_zero);
    }

    var i: usize = 0;
    while (i < new_length) {
        const value = depth[i];
        var reps: usize = 1;
        if ((value != 0 and use_rle_for_non_zero) or (value == 0 and use_rle_for_zero)) {
            while (i + reps < new_length and depth[i + reps] == value) : (reps += 1) {}
        }
        if (value == 0) {
            brotliWriteHuffmanTreeRepetitionsZeros(reps, tree_size, tree, extra_bits_data);
        } else {
            brotliWriteHuffmanTreeRepetitions(previous_value, value, reps, tree_size, tree, extra_bits_data);
            previous_value = value;
        }
        i += reps;
    }
}

const kStorageOrder = [_]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const kHuffmanBitLengthHuffmanCodeSymbols = [_]u8{ 0, 7, 3, 2, 1, 15 };
const kHuffmanBitLengthHuffmanCodeBitLengths = [_]u8{ 2, 4, 3, 2, 2, 4 };

fn brotliStoreHuffmanTreeOfHuffmanTreeToBitMask(
    num_codes: i32,
    code_length_bitdepth: *const [18]u8,
    storage_ix: *usize,
    storage: []u8,
) void {
    var skip_some: usize = 0;
    var codes_to_store: usize = 18;
    if (num_codes > 1) {
        while (codes_to_store > 0) : (codes_to_store -= 1) {
            if (code_length_bitdepth[kStorageOrder[codes_to_store - 1]] != 0) break;
        }
    }
    if (code_length_bitdepth[kStorageOrder[0]] == 0 and code_length_bitdepth[kStorageOrder[1]] == 0) {
        skip_some = 2;
        if (code_length_bitdepth[kStorageOrder[2]] == 0) {
            skip_some = 3;
        }
    }
    bit_writer.writeBits(2, skip_some, storage_ix, storage);
    var i = skip_some;
    while (i < codes_to_store) : (i += 1) {
        const l = code_length_bitdepth[kStorageOrder[i]];
        bit_writer.writeBits(
            @intCast(kHuffmanBitLengthHuffmanCodeBitLengths[l]),
            kHuffmanBitLengthHuffmanCodeSymbols[l],
            storage_ix,
            storage,
        );
    }
}

fn brotliStoreHuffmanTreeToBitMask(
    huffman_tree: []const u8,
    huffman_tree_extra_bits: []const u8,
    code_length_bitdepth: *const [18]u8,
    code_length_bitdepth_symbols: *const [18]u16,
    storage_ix: *usize,
    storage: []u8,
) void {
    for (huffman_tree, 0..) |ix, i| {
        bit_writer.writeBits(@intCast(code_length_bitdepth[ix]), code_length_bitdepth_symbols[ix], storage_ix, storage);
        switch (ix) {
            constants.REPEAT_PREVIOUS_CODE_LENGTH => {
                bit_writer.writeBits(2, huffman_tree_extra_bits[i], storage_ix, storage);
            },
            constants.REPEAT_ZERO_CODE_LENGTH => {
                bit_writer.writeBits(3, huffman_tree_extra_bits[i], storage_ix, storage);
            },
            else => {},
        }
    }
}

pub fn brotliStoreHuffmanTree(
    depths: []const u8,
    tree: []HuffmanTree,
    storage_ix: *usize,
    storage: []u8,
) void {
    var huffman_tree: [constants.NUM_COMMAND_SYMBOLS]u8 = undefined;
    var huffman_tree_extra_bits: [constants.NUM_COMMAND_SYMBOLS]u8 = undefined;
    var huffman_tree_size: usize = 0;
    var code_length_bitdepth: [18]u8 = @splat(0);
    var code_length_bitdepth_symbols: [18]u16 = undefined;
    var huffman_tree_histogram: [18]u32 = @splat(0);

    brotliWriteHuffmanTree(depths, &huffman_tree_size, &huffman_tree, &huffman_tree_extra_bits);

    for (huffman_tree[0..huffman_tree_size]) |sym| {
        huffman_tree_histogram[sym] += 1;
    }

    var num_codes: i32 = 0;
    var code: usize = 0;
    for (0..18) |i| {
        if (huffman_tree_histogram[i] != 0) {
            if (num_codes == 0) {
                code = i;
                num_codes = 1;
            } else if (num_codes == 1) {
                num_codes = 2;
                break;
            }
        }
    }

    brotliCreateHuffmanTree(&huffman_tree_histogram, 5, tree, &code_length_bitdepth);
    brotliConvertBitDepthsToSymbols(&code_length_bitdepth, &code_length_bitdepth_symbols);

    brotliStoreHuffmanTreeOfHuffmanTreeToBitMask(num_codes, &code_length_bitdepth, storage_ix, storage);

    if (num_codes == 1) {
        code_length_bitdepth[code] = 0;
    }

    brotliStoreHuffmanTreeToBitMask(
        huffman_tree[0..huffman_tree_size],
        huffman_tree_extra_bits[0..huffman_tree_size],
        &code_length_bitdepth,
        &code_length_bitdepth_symbols,
        storage_ix,
        storage,
    );
}

pub fn buildAndStoreLiteralPrefixCode(
    s: *OnePassArena,
    input: []const u8,
    depths: *[256]u8,
    bits: *[256]u16,
    storage_ix: *usize,
    storage: []u8,
) usize {
    @memset(&s.histogram, 0);
    var histogram_total: usize = 0;
    if (input.len < (1 << 15)) {
        for (input) |b| s.histogram[b] += 1;
        histogram_total = input.len;
        for (0..256) |sym| {
            const min_val: u32 = @min(s.histogram[sym], @as(u32, 11));
            const adjust: u32 = 2 * min_val;
            s.histogram[sym] += adjust;
            histogram_total += adjust;
        }
    } else {
        const kSampleRate = 29;
        var i: usize = 0;
        while (i < input.len) : (i += kSampleRate) {
            s.histogram[input[i]] += 1;
        }
        histogram_total = (input.len + kSampleRate - 1) / kSampleRate;
        for (0..256) |sym| {
            const min_val: u32 = @min(s.histogram[sym], @as(u32, 11));
            const adjust: u32 = 1 + 2 * min_val;
            s.histogram[sym] += adjust;
            histogram_total += adjust;
        }
    }
    buildAndStoreHuffmanTreeFast(&s.tree, &s.histogram, histogram_total, 8, depths, bits, storage_ix, storage);
    var literal_ratio: usize = 0;
    for (0..256) |sym| {
        if (s.histogram[sym] != 0) literal_ratio += s.histogram[sym] * depths[sym];
    }
    return (literal_ratio * 125) / histogram_total;
}

pub fn buildAndStoreCommandPrefixCode(
    s: *OnePassArena,
    storage_ix: *usize,
    storage: []u8,
) void {
    @memset(&s.tmp_depth, 0);
    brotliCreateHuffmanTree(s.cmd_histo[0..64], 15, &s.tree, s.cmd_depth[0..64]);
    brotliCreateHuffmanTree(s.cmd_histo[64..128], 14, &s.tree, s.cmd_depth[64..128]);

    @memcpy(s.tmp_depth[0..24], s.cmd_depth[0..24]);
    @memcpy(s.tmp_depth[24..32], s.cmd_depth[40..48]);
    @memcpy(s.tmp_depth[32..40], s.cmd_depth[24..32]);
    @memcpy(s.tmp_depth[40..48], s.cmd_depth[48..56]);
    @memcpy(s.tmp_depth[48..56], s.cmd_depth[32..40]);
    @memcpy(s.tmp_depth[56..64], s.cmd_depth[56..64]);

    brotliConvertBitDepthsToSymbols(s.tmp_depth[0..64], s.tmp_bits[0..64]);
    @memcpy(s.cmd_bits[0..24], s.tmp_bits[0..24]);
    @memcpy(s.cmd_bits[24..32], s.tmp_bits[32..40]);
    @memcpy(s.cmd_bits[32..40], s.tmp_bits[48..56]);
    @memcpy(s.cmd_bits[40..48], s.tmp_bits[24..32]);
    @memcpy(s.cmd_bits[48..56], s.tmp_bits[40..48]);
    @memcpy(s.cmd_bits[56..64], s.tmp_bits[56..64]);

    brotliConvertBitDepthsToSymbols(s.cmd_depth[64..128], s.cmd_bits[64..128]);

    @memset(s.tmp_depth[0..64], 0);
    @memcpy(s.tmp_depth[0..8], s.cmd_depth[0..8]);
    @memcpy(s.tmp_depth[64..72], s.cmd_depth[8..16]);
    @memcpy(s.tmp_depth[128..136], s.cmd_depth[16..24]);
    @memcpy(s.tmp_depth[192..200], s.cmd_depth[24..32]);
    @memcpy(s.tmp_depth[384..392], s.cmd_depth[32..40]);
    for (0..8) |i| {
        s.tmp_depth[128 + 8 * i] = s.cmd_depth[40 + i];
        s.tmp_depth[256 + 8 * i] = s.cmd_depth[48 + i];
        s.tmp_depth[448 + 8 * i] = s.cmd_depth[56 + i];
    }
    brotliStoreHuffmanTree(s.tmp_depth[0..constants.NUM_COMMAND_SYMBOLS], &s.tree, storage_ix, storage);
    brotliStoreHuffmanTree(s.cmd_depth[64..128], &s.tree, storage_ix, storage);
}

inline fn emitInsertLen(
    insertlen: usize,
    depth: *const [128]u8,
    bits: *const [128]u16,
    histo: *[128]u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    if (insertlen < 6) {
        const code = insertlen + 40;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        histo[code] += 1;
    } else if (insertlen < 130) {
        const tail = insertlen - 2;
        const nbits = std.math.log2_int(usize, tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const inscode = (nbits << 1) + prefix + 42;
        bit_writer.writeBits(@intCast(depth[inscode]), bits[inscode], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (prefix << @intCast(nbits)), storage_ix, storage);
        histo[inscode] += 1;
    } else if (insertlen < 2114) {
        const tail = insertlen - 66;
        const nbits = std.math.log2_int(usize, tail);
        const code: usize = @as(usize, nbits) + 50;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (@as(usize, 1) << @intCast(nbits)), storage_ix, storage);
        histo[code] += 1;
    } else {
        bit_writer.writeBits(@intCast(depth[61]), bits[61], storage_ix, storage);
        bit_writer.writeBits(12, insertlen - 2114, storage_ix, storage);
        histo[61] += 1;
    }
}

inline fn emitLongInsertLen(
    insertlen: usize,
    depth: *const [128]u8,
    bits: *const [128]u16,
    histo: *[128]u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    if (insertlen < 22594) {
        bit_writer.writeBits(@intCast(depth[62]), bits[62], storage_ix, storage);
        bit_writer.writeBits(14, insertlen - 6210, storage_ix, storage);
        histo[62] += 1;
    } else {
        bit_writer.writeBits(@intCast(depth[63]), bits[63], storage_ix, storage);
        bit_writer.writeBits(24, insertlen - 22594, storage_ix, storage);
        histo[63] += 1;
    }
}

inline fn emitCopyLen(
    copylen: usize,
    depth: *const [128]u8,
    bits: *const [128]u16,
    histo: *[128]u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    if (copylen < 10) {
        const code = copylen + 14;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        histo[code] += 1;
    } else if (copylen < 134) {
        const tail = copylen - 6;
        const nbits = std.math.log2_int(usize, tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const code = (nbits << 1) + prefix + 20;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (prefix << @intCast(nbits)), storage_ix, storage);
        histo[code] += 1;
    } else if (copylen < 2118) {
        const tail = copylen - 70;
        const nbits = std.math.log2_int(usize, tail);
        const code = nbits + 28;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (@as(usize, 1) << @intCast(nbits)), storage_ix, storage);
        histo[code] += 1;
    } else {
        bit_writer.writeBits(@intCast(depth[39]), bits[39], storage_ix, storage);
        bit_writer.writeBits(24, copylen - 2118, storage_ix, storage);
        histo[39] += 1;
    }
}

inline fn emitCopyLenLastDistance(
    copylen: usize,
    depth: *const [128]u8,
    bits: *const [128]u16,
    histo: *[128]u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    if (copylen < 12) {
        const code = copylen - 4;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        histo[code] += 1;
    } else if (copylen < 72) {
        const tail = copylen - 8;
        const nbits = std.math.log2_int(usize, tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const code = (nbits << 1) + prefix + 4;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (prefix << @intCast(nbits)), storage_ix, storage);
        histo[code] += 1;
    } else if (copylen < 136) {
        const tail = copylen - 8;
        const code = (tail >> 5) + 30;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(5, tail & 31, storage_ix, storage);
        bit_writer.writeBits(@intCast(depth[64]), bits[64], storage_ix, storage);
        histo[code] += 1;
        histo[64] += 1;
    } else if (copylen < 2120) {
        const tail = copylen - 72;
        const nbits = std.math.log2_int(usize, tail);
        const code = nbits + 28;
        bit_writer.writeBits(@intCast(depth[code]), bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(nbits), tail - (@as(usize, 1) << @intCast(nbits)), storage_ix, storage);
        bit_writer.writeBits(@intCast(depth[64]), bits[64], storage_ix, storage);
        histo[code] += 1;
        histo[64] += 1;
    } else {
        bit_writer.writeBits(@intCast(depth[39]), bits[39], storage_ix, storage);
        bit_writer.writeBits(24, copylen - 2120, storage_ix, storage);
        bit_writer.writeBits(@intCast(depth[64]), bits[64], storage_ix, storage);
        histo[39] += 1;
        histo[64] += 1;
    }
}

inline fn emitDistance(
    distance: usize,
    depth: *const [128]u8,
    bits: *const [128]u16,
    histo: *[128]u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    const d = distance + 3;
    const nbits = std.math.log2_int(usize, d) - 1;
    const prefix = (d >> @intCast(nbits)) & 1;
    const offset = (2 + prefix) << @intCast(nbits);
    const distcode = 2 * (nbits - 1) + prefix + 80;
    bit_writer.writeBits(@intCast(depth[distcode]), bits[distcode], storage_ix, storage);
    bit_writer.writeBits(@intCast(nbits), d - offset, storage_ix, storage);
    histo[distcode] += 1;
}

inline fn emitLiterals(
    input: []const u8,
    depth: *const [256]u8,
    bits: *const [256]u16,
    storage_ix: *usize,
    storage: []u8,
) void {
    for (input) |lit| {
        bit_writer.writeBits(@intCast(depth[lit]), bits[lit], storage_ix, storage);
    }
}

fn storeMetaBlockHeader(len: usize, is_uncompressed: bool, storage_ix: *usize, storage: []u8) void {
    var nibbles: usize = 6;
    bit_writer.writeBits(1, 0, storage_ix, storage); // ISLAST = 0
    if (len <= (1 << 16)) {
        nibbles = 4;
    } else if (len <= (1 << 20)) {
        nibbles = 5;
    }
    bit_writer.writeBits(2, nibbles - 4, storage_ix, storage);
    bit_writer.writeBits(@intCast(nibbles * 4), len - 1, storage_ix, storage);
    bit_writer.writeBits(1, if (is_uncompressed) 1 else 0, storage_ix, storage);
}

fn updateBits(n_bits_in: usize, bits_in: u32, pos_in: usize, array: []u8) void {
    var n_bits = n_bits_in;
    var bits = bits_in;
    var pos = pos_in;
    while (n_bits > 0) {
        const byte_pos = pos >> 3;
        const n_unchanged_bits = pos & 7;
        const n_changed_bits = @min(n_bits, 8 - n_unchanged_bits);
        const total_bits = n_unchanged_bits + n_changed_bits;
        const mask = (~((@as(u32, 1) << @intCast(total_bits)) - 1)) | ((@as(u32, 1) << @intCast(n_unchanged_bits)) - 1);
        const unchanged_bits = @as(u32, array[byte_pos]) & mask;
        const changed_bits = bits & ((@as(u32, 1) << @intCast(n_changed_bits)) - 1);
        array[byte_pos] = @truncate((changed_bits << @intCast(n_unchanged_bits)) | unchanged_bits);
        n_bits -= n_changed_bits;
        bits >>= @intCast(n_changed_bits);
        pos += n_changed_bits;
    }
}

fn rewindBitPosition(new_storage_ix: usize, storage_ix: *usize, storage: []u8) void {
    const bitpos = new_storage_ix & 7;
    const mask = (@as(u32, 1) << @intCast(bitpos)) - 1;
    storage[new_storage_ix >> 3] &= @truncate(mask);
    storage_ix.* = new_storage_ix;
}

noinline fn shouldMergeBlock(
    s: *OnePassArena,
    data: []const u8,
    depths: *const [256]u8,
) bool {
    const kSampleRate = 43;
    @memset(&s.histogram, 0);
    var i: usize = 0;
    while (i < data.len) : (i += kSampleRate) {
        s.histogram[data[i]] += 1;
    }
    const total = (data.len + kSampleRate - 1) / kSampleRate;
    var r = (fast_log.fastLog2(total) + 0.5) * @as(f64, @floatFromInt(total)) + 200.0;
    for (0..256) |sym| {
        r -= @as(f64, @floatFromInt(s.histogram[sym])) * (@as(f64, @floatFromInt(depths[sym])) + fast_log.fastLog2(s.histogram[sym]));
    }
    return r >= 0.0;
}

inline fn shouldUseUncompressedMode(
    metablock_start_idx: usize,
    next_emit_idx: usize,
    insertlen: usize,
    literal_ratio: usize,
) bool {
    const compressed = next_emit_idx - metablock_start_idx;
    if (compressed * 50 > insertlen) {
        return false;
    } else {
        return literal_ratio > MIN_RATIO;
    }
}

fn emitUncompressedMetaBlock(
    input_slice: []const u8,
    storage_ix_start: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    rewindBitPosition(storage_ix_start, storage_ix, storage);
    storeMetaBlockHeader(input_slice.len, true, storage_ix, storage);
    storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
    const byte_start = storage_ix.* >> 3;
    @memcpy(storage[byte_start .. byte_start + input_slice.len], input_slice);
    storage_ix.* += input_slice.len << 3;
    storage[storage_ix.* >> 3] = 0;
}

fn compressFragmentFastImpl(
    s: *OnePassArena,
    full_input: []const u8,
    is_last: bool,
    table: []i32,
    table_bits: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    const shift: u6 = @intCast(64 - table_bits);
    var input_offset: usize = 0;
    var input_size = full_input.len;
    var metablock_start = input_offset;
    var next_emit = input_offset;
    const base_ip = input_offset;

    var block_size: usize = @min(input_size, kFirstBlockSize);
    var total_block_size: usize = block_size;
    var mlen_storage_ix = storage_ix.* + 3;

    storeMetaBlockHeader(block_size, false, storage_ix, storage);
    bit_writer.writeBits(13, 0, storage_ix, storage); // No block splits, no contexts

    var literal_ratio = buildAndStoreLiteralPrefixCode(
        s,
        full_input[input_offset .. input_offset + block_size],
        &s.lit_depth,
        &s.lit_bits,
        storage_ix,
        storage,
    );

    // Pre-compressed command prefix codes
    var bit_idx: usize = 0;
    while (bit_idx + 7 < s.cmd_code_numbits) : (bit_idx += 8) {
        bit_writer.writeBits(8, s.cmd_code[bit_idx >> 3], storage_ix, storage);
    }
    bit_writer.writeBits(@intCast(s.cmd_code_numbits & 7), s.cmd_code[s.cmd_code_numbits >> 3], storage_ix, storage);

    while (true) {
        // emit_commands:
        s.cmd_histo = kCmdHistoSeed;
        var ip = input_offset;
        var last_distance: isize = -1;
        const ip_end = input_offset + block_size;
        var goto_next_block = false;

        if (block_size >= kInputMarginBytes) {
            const len_limit = @min(block_size - kMinMatchLen, input_size - kInputMarginBytes);
            const ip_limit = input_offset + len_limit;

            ip += 1;
            var next_hash = hash(full_input[ip..], shift);

            main_loop: while (true) {
                var skip: u32 = 32;
                var next_ip = ip;
                var candidate: usize = undefined;

                while (true) {
                    const h = next_hash;
                    const bytes_between_hash_lookups: usize = skip >> 5;
                    skip += 1;
                    ip = next_ip;
                    next_ip = ip + bytes_between_hash_lookups;
                    if (next_ip > ip_limit) {
                        break :main_loop;
                    }
                    next_hash = hash(full_input[next_ip..], shift);
                    if (last_distance >= 0 and ip >= @as(usize, @intCast(last_distance))) {
                        candidate = ip - @as(usize, @intCast(last_distance));
                        if (isMatch(full_input[ip..], full_input[candidate..])) {
                            if (candidate < ip) {
                                table[h] = @intCast(ip - base_ip);
                                break;
                            }
                        }
                    }
                    candidate = base_ip + @as(usize, @intCast(table[h]));
                    table[h] = @intCast(ip - base_ip);

                    if (isMatch(full_input[ip..], full_input[candidate..])) {
                        if (ip - candidate <= MAX_DISTANCE) {
                            break;
                        }
                    }
                }

                // Match found at ip
                const base = ip;
                const matched = 5 + findMatchLengthWithLimit(
                    full_input[candidate + 5 ..],
                    full_input[ip + 5 ..],
                    (ip_end - ip) - 5,
                );
                const distance: isize = @intCast(base - candidate);
                const insert = base - next_emit;
                ip += matched;

                if (insert < 6210) {
                    emitInsertLen(insert, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                } else if (shouldUseUncompressedMode(metablock_start, next_emit, insert, literal_ratio)) {
                    emitUncompressedMetaBlock(full_input[metablock_start..base], mlen_storage_ix - 3, storage_ix, storage);
                    input_size -= (base - input_offset);
                    input_offset = base;
                    next_emit = input_offset;
                    goto_next_block = true;
                    break :main_loop;
                } else {
                    emitLongInsertLen(insert, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                }

                emitLiterals(full_input[next_emit .. next_emit + insert], &s.lit_depth, &s.lit_bits, storage_ix, storage);

                if (distance == last_distance) {
                    bit_writer.writeBits(@intCast(s.cmd_depth[64]), s.cmd_bits[64], storage_ix, storage);
                    s.cmd_histo[64] += 1;
                } else {
                    emitDistance(@intCast(distance), &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                    last_distance = distance;
                }
                emitCopyLenLastDistance(matched, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);

                next_emit = ip;
                if (ip >= ip_limit) {
                    break :main_loop;
                }

                {
                    const input_bytes = std.mem.readInt(u64, full_input[ip - 3 ..][0..8], .little);
                    var prev_h = hashBytesAtOffset(input_bytes, 0, shift);
                    const cur_h = hashBytesAtOffset(input_bytes, 3, shift);
                    table[prev_h] = @intCast(ip - base_ip - 3);
                    prev_h = hashBytesAtOffset(input_bytes, 1, shift);
                    table[prev_h] = @intCast(ip - base_ip - 2);
                    prev_h = hashBytesAtOffset(input_bytes, 2, shift);
                    table[prev_h] = @intCast(ip - base_ip - 1);

                    candidate = base_ip + @as(usize, @intCast(table[cur_h]));
                    table[cur_h] = @intCast(ip - base_ip);
                }

                while (isMatch(full_input[ip..], full_input[candidate..])) {
                    const match_base = ip;
                    const copy_matched = 5 + findMatchLengthWithLimit(
                        full_input[candidate + 5 ..],
                        full_input[ip + 5 ..],
                        (ip_end - ip) - 5,
                    );
                    if (ip - candidate > MAX_DISTANCE) break;
                    ip += copy_matched;
                    last_distance = @intCast(match_base - candidate);
                    emitCopyLen(copy_matched, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                    emitDistance(@intCast(last_distance), &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);

                    next_emit = ip;
                    if (ip >= ip_limit) {
                        break :main_loop;
                    }
                    {
                        const input_bytes = std.mem.readInt(u64, full_input[ip - 3 ..][0..8], .little);
                        var prev_h = hashBytesAtOffset(input_bytes, 0, shift);
                        const cur_h = hashBytesAtOffset(input_bytes, 3, shift);
                        table[prev_h] = @intCast(ip - base_ip - 3);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift);
                        table[prev_h] = @intCast(ip - base_ip - 2);
                        prev_h = hashBytesAtOffset(input_bytes, 2, shift);
                        table[prev_h] = @intCast(ip - base_ip - 1);

                        candidate = base_ip + @as(usize, @intCast(table[cur_h]));
                        table[cur_h] = @intCast(ip - base_ip);
                    }
                }

                ip += 1;
                next_hash = hash(full_input[ip..], shift);
            }
        }

        if (!goto_next_block) {
            // emit_remainder:
            input_offset += block_size;
            input_size -= block_size;
            block_size = @min(input_size, kMergeBlockSize);

            if (input_size > 0 and total_block_size + block_size <= (1 << 20) and shouldMergeBlock(s, full_input[input_offset .. input_offset + block_size], &s.lit_depth)) {
                total_block_size += block_size;
                updateBits(20, @intCast(total_block_size - 1), mlen_storage_ix, storage);
                continue; // goto emit_commands
            }

            if (next_emit < ip_end) {
                const insert = ip_end - next_emit;
                if (insert < 6210) {
                    emitInsertLen(insert, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                    emitLiterals(full_input[next_emit..ip_end], &s.lit_depth, &s.lit_bits, storage_ix, storage);
                } else if (shouldUseUncompressedMode(metablock_start, next_emit, insert, literal_ratio)) {
                    emitUncompressedMetaBlock(full_input[metablock_start..ip_end], mlen_storage_ix - 3, storage_ix, storage);
                } else {
                    emitLongInsertLen(insert, &s.cmd_depth, &s.cmd_bits, &s.cmd_histo, storage_ix, storage);
                    emitLiterals(full_input[next_emit..ip_end], &s.lit_depth, &s.lit_bits, storage_ix, storage);
                }
            }
            next_emit = ip_end;
        }

        // next_block:
        if (input_size > 0) {
            metablock_start = input_offset;
            block_size = @min(input_size, kFirstBlockSize);
            total_block_size = block_size;
            mlen_storage_ix = storage_ix.* + 3;
            storeMetaBlockHeader(block_size, false, storage_ix, storage);
            bit_writer.writeBits(13, 0, storage_ix, storage);
            literal_ratio = buildAndStoreLiteralPrefixCode(s, full_input[input_offset .. input_offset + block_size], &s.lit_depth, &s.lit_bits, storage_ix, storage);
            buildAndStoreCommandPrefixCode(s, storage_ix, storage);
            continue;
        }

        if (!is_last) {
            s.cmd_code[0] = 0;
            s.cmd_code_numbits = 0;
            buildAndStoreCommandPrefixCode(s, &s.cmd_code_numbits, &s.cmd_code);
        }
        break;
    }
}

pub fn compressFragmentFast(
    s: *OnePassArena,
    input: []const u8,
    is_last: bool,
    table: []i32,
    storage_ix: *usize,
    storage: []u8,
) void {
    const initial_storage_ix = storage_ix.*;
    const table_bits = std.math.log2_int(usize, table.len);

    if (input.len == 0) {
        if (is_last) {
            bit_writer.writeBits(1, 1, storage_ix, storage); // islast
            bit_writer.writeBits(1, 1, storage_ix, storage); // isempty
            storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
        }
        return;
    }

    compressFragmentFastImpl(s, input, is_last, table, table_bits, storage_ix, storage);

    // If output is larger than single uncompressed block, rewrite it.
    if (storage_ix.* - initial_storage_ix > 31 + (input.len << 3)) {
        emitUncompressedMetaBlock(input, initial_storage_ix, storage_ix, storage);
    }

    if (is_last) {
        bit_writer.writeBits(1, 1, storage_ix, storage); // islast
        bit_writer.writeBits(1, 1, storage_ix, storage); // isempty
        storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
    }
}
