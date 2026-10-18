//! Fast two-pass fragment compression (Quality 1).
//!
//! Emits two-pass compressed metablocks with dynamic command and literal entropy trees.

const std = @import("std");
const bit_writer = @import("../bitstream/bit_writer.zig");
const constants = @import("../common/constants.zig");
const fast_log = @import("fast_log.zig");
const compress_fragment = @import("compress_fragment.zig");

pub const HuffmanTree = compress_fragment.HuffmanTree;
pub const BROTLI_WINDOW_GAP: usize = 16;
pub const MAX_DISTANCE: isize = (1 << 18) - 16;
pub const kHashMul32: u32 = 0x1E35A7BD;
pub const kCompressFragmentTwoPassBlockSize: usize = 1 << 17;
pub const MIN_RATIO: f64 = 0.98;
pub const SAMPLE_RATE: usize = 43;

pub const TwoPassArena = struct {
    lit_histo: [256]u32 = @splat(0),
    lit_depth: [256]u8 = @splat(0),
    lit_bits: [256]u16 = @splat(0),

    cmd_histo: [128]u32 = @splat(0),
    cmd_depth: [128]u8 = @splat(0),
    cmd_bits: [128]u16 = @splat(0),

    tmp_tree: [2 * constants.NUM_LITERAL_SYMBOLS + 1]HuffmanTree = undefined,
    tmp_depth: [constants.NUM_COMMAND_SYMBOLS]u8 = @splat(0),
    tmp_bits: [64]u16 = @splat(0),

    pub fn init() TwoPassArena {
        return .{};
    }
};

pub const kNumExtraBits = [128]u8{
    0,  0,  0,  0,  0,  0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,
    6,  7,  8,  9,  10, 12, 14, 24, 0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  7,  8,  9,  10, 24,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,  8,  8,
    9,  9,  10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
    17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 24,
};

pub const kInsertOffset = [24]u32{
    0,  1,  2,  3,  4,   5,   6,   8,   10,   14,   18,   26,
    34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
};

inline fn hash(p: []const u8, shift: u6, length: usize) u32 {
    const val = std.mem.readInt(u64, p[0..8], .little);
    const h = (val << @intCast((8 - length) * 8)) *% @as(u64, kHashMul32);
    return @truncate(h >> shift);
}

inline fn hashBytesAtOffset(v: u64, offset: usize, shift: u6, length: usize) u32 {
    const h = ((v >> @intCast(8 * offset)) << @intCast((8 - length) * 8)) *% @as(u64, kHashMul32);
    return @truncate(h >> shift);
}

inline fn isMatch(p1: []const u8, p2: []const u8, length: usize) bool {
    const v1 = std.mem.readInt(u32, p1[0..4], .little);
    const v2 = std.mem.readInt(u32, p2[0..4], .little);
    if (v1 == v2) {
        if (length == 4) return true;
        return (p1[4] == p2[4] and p1[5] == p2[5]);
    }
    return false;
}

pub fn brotliBitsEntropy(population: []const u32) f64 {
    var sum: usize = 0;
    var retval: f64 = 0;
    for (population) |p| {
        sum += p;
        if (p != 0) {
            retval -= @as(f64, @floatFromInt(p)) * fast_log.fastLog2(p);
        }
    }
    if (sum != 0) {
        retval += @as(f64, @floatFromInt(sum)) * fast_log.fastLog2(sum);
    }
    if (retval < @as(f64, @floatFromInt(sum))) {
        retval = @as(f64, @floatFromInt(sum));
    }
    return retval;
}

fn buildAndStoreCommandPrefixCode(
    s: *TwoPassArena,
    storage_ix: *usize,
    storage: []u8,
) void {
    @memset(&s.tmp_depth, 0);
    compress_fragment.brotliCreateHuffmanTree(s.cmd_histo[0..64], 15, &s.tmp_tree, s.cmd_depth[0..64]);
    compress_fragment.brotliCreateHuffmanTree(s.cmd_histo[64..128], 14, &s.tmp_tree, s.cmd_depth[64..128]);

    @memcpy(s.tmp_depth[0..24], s.cmd_depth[24..48]);
    @memcpy(s.tmp_depth[24..32], s.cmd_depth[0..8]);
    @memcpy(s.tmp_depth[32..40], s.cmd_depth[48..56]);
    @memcpy(s.tmp_depth[40..48], s.cmd_depth[8..16]);
    @memcpy(s.tmp_depth[48..56], s.cmd_depth[56..64]);
    @memcpy(s.tmp_depth[56..64], s.cmd_depth[16..24]);

    compress_fragment.brotliConvertBitDepthsToSymbols(s.tmp_depth[0..64], s.tmp_bits[0..64]);

    @memcpy(s.cmd_bits[0..8], s.tmp_bits[24..32]);
    @memcpy(s.cmd_bits[8..16], s.tmp_bits[40..48]);
    @memcpy(s.cmd_bits[16..24], s.tmp_bits[56..64]);
    @memcpy(s.cmd_bits[24..48], s.tmp_bits[0..24]);
    @memcpy(s.cmd_bits[48..56], s.tmp_bits[32..40]);
    @memcpy(s.cmd_bits[56..64], s.tmp_bits[48..56]);

    compress_fragment.brotliConvertBitDepthsToSymbols(s.cmd_depth[64..128], s.cmd_bits[64..128]);

    @memset(s.tmp_depth[0..64], 0);
    @memcpy(s.tmp_depth[0..8], s.cmd_depth[24..32]);
    @memcpy(s.tmp_depth[64..72], s.cmd_depth[32..40]);
    @memcpy(s.tmp_depth[128..136], s.cmd_depth[40..48]);
    @memcpy(s.tmp_depth[192..200], s.cmd_depth[48..56]);
    @memcpy(s.tmp_depth[384..392], s.cmd_depth[56..64]);
    for (0..8) |i| {
        s.tmp_depth[128 + 8 * i] = s.cmd_depth[i];
        s.tmp_depth[256 + 8 * i] = s.cmd_depth[8 + i];
        s.tmp_depth[448 + 8 * i] = s.cmd_depth[16 + i];
    }

    compress_fragment.brotliStoreHuffmanTree(s.tmp_depth[0..constants.NUM_COMMAND_SYMBOLS], &s.tmp_tree, storage_ix, storage);
    compress_fragment.brotliStoreHuffmanTree(s.cmd_depth[64..128], &s.tmp_tree, storage_ix, storage);
}

inline fn emitInsertLen(insertlen: u32, commands: []u32, cmd_idx: *usize) void {
    if (insertlen < 6) {
        commands[cmd_idx.*] = insertlen;
    } else if (insertlen < 130) {
        const tail = insertlen - 2;
        const nbits = fast_log.log2FloorNonZero(tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const inscode = (nbits << 1) + prefix + 2;
        const extra = tail - (prefix << @intCast(nbits));
        commands[cmd_idx.*] = inscode | (extra << 8);
    } else if (insertlen < 2114) {
        const tail = insertlen - 66;
        const nbits = fast_log.log2FloorNonZero(tail);
        const code = nbits + 10;
        const extra = tail - (@as(u32, 1) << @intCast(nbits));
        commands[cmd_idx.*] = code | (extra << 8);
    } else if (insertlen < 6210) {
        const extra = insertlen - 2114;
        commands[cmd_idx.*] = 21 | (extra << 8);
    } else if (insertlen < 22594) {
        const extra = insertlen - 6210;
        commands[cmd_idx.*] = 22 | (extra << 8);
    } else {
        const extra = insertlen - 22594;
        commands[cmd_idx.*] = 23 | (extra << 8);
    }
    cmd_idx.* += 1;
}

inline fn emitCopyLen(copylen: usize, commands: []u32, cmd_idx: *usize) void {
    if (copylen < 10) {
        commands[cmd_idx.*] = @intCast(copylen + 38);
    } else if (copylen < 134) {
        const tail = copylen - 6;
        const nbits = fast_log.log2FloorNonZero(tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const code = (nbits << 1) + prefix + 44;
        const extra = tail - (prefix << @intCast(nbits));
        commands[cmd_idx.*] = @intCast(code | (extra << 8));
    } else if (copylen < 2118) {
        const tail = copylen - 70;
        const nbits = fast_log.log2FloorNonZero(tail);
        const code = nbits + 52;
        const extra = tail - (@as(usize, 1) << @intCast(nbits));
        commands[cmd_idx.*] = @intCast(code | (extra << 8));
    } else {
        const extra = copylen - 2118;
        commands[cmd_idx.*] = @intCast(63 | (extra << 8));
    }
    cmd_idx.* += 1;
}

inline fn emitCopyLenLastDistance(copylen: usize, commands: []u32, cmd_idx: *usize) void {
    if (copylen < 12) {
        commands[cmd_idx.*] = @intCast(copylen + 20);
        cmd_idx.* += 1;
    } else if (copylen < 72) {
        const tail = copylen - 8;
        const nbits = fast_log.log2FloorNonZero(tail) - 1;
        const prefix = tail >> @intCast(nbits);
        const code = (nbits << 1) + prefix + 28;
        const extra = tail - (prefix << @intCast(nbits));
        commands[cmd_idx.*] = @intCast(code | (extra << 8));
        cmd_idx.* += 1;
    } else if (copylen < 136) {
        const tail = copylen - 8;
        const code = (tail >> 5) + 54;
        const extra = tail & 31;
        commands[cmd_idx.*] = @intCast(code | (extra << 8));
        cmd_idx.* += 1;
        commands[cmd_idx.*] = 64;
        cmd_idx.* += 1;
    } else if (copylen < 2120) {
        const tail = copylen - 72;
        const nbits = fast_log.log2FloorNonZero(tail);
        const code = nbits + 52;
        const extra = tail - (@as(usize, 1) << @intCast(nbits));
        commands[cmd_idx.*] = @intCast(code | (extra << 8));
        cmd_idx.* += 1;
        commands[cmd_idx.*] = 64;
        cmd_idx.* += 1;
    } else {
        const extra = copylen - 2120;
        commands[cmd_idx.*] = @intCast(63 | (extra << 8));
        cmd_idx.* += 1;
        commands[cmd_idx.*] = 64;
        cmd_idx.* += 1;
    }
}

inline fn emitDistance(distance: u32, commands: []u32, cmd_idx: *usize) void {
    const d = distance + 3;
    const nbits = fast_log.log2FloorNonZero(d) - 1;
    const prefix = (d >> @intCast(nbits)) & 1;
    const offset = (2 + prefix) << @intCast(nbits);
    const distcode = 2 * (nbits - 1) + prefix + 80;
    const extra = d - offset;
    commands[cmd_idx.*] = distcode | (extra << 8);
    cmd_idx.* += 1;
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

fn rewindBitPosition(new_storage_ix: usize, storage_ix: *usize, storage: []u8) void {
    const bitpos = new_storage_ix & 7;
    const mask = (@as(usize, 1) << @intCast(bitpos)) - 1;
    storage[new_storage_ix >> 3] &= @truncate(mask);
    storage_ix.* = new_storage_ix;
}

fn emitUncompressedMetaBlock(input: []const u8, storage_ix: *usize, storage: []u8) void {
    storeMetaBlockHeader(input.len, true, storage_ix, storage);
    storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
    @memcpy(storage[storage_ix.* >> 3 ..][0..input.len], input);
    storage_ix.* += input.len << 3;
    storage[storage_ix.* >> 3] = 0;
}

fn shouldCompress(s: *TwoPassArena, input: []const u8, num_literals: usize) bool {
    const corpus_size: f64 = @floatFromInt(input.len);
    if (@as(f64, @floatFromInt(num_literals)) < MIN_RATIO * corpus_size) {
        return true;
    } else {
        const max_total_bit_cost = corpus_size * 8.0 * MIN_RATIO / @as(f64, @floatFromInt(SAMPLE_RATE));
        @memset(&s.lit_histo, 0);
        var i: usize = 0;
        while (i < input.len) : (i += SAMPLE_RATE) {
            s.lit_histo[input[i]] += 1;
        }
        return brotliBitsEntropy(&s.lit_histo) < max_total_bit_cost;
    }
}

fn storeCommands(
    s: *TwoPassArena,
    literals: []const u8,
    commands: []const u32,
    storage_ix: *usize,
    storage: []u8,
) void {
    @memset(&s.lit_histo, 0);
    @memset(&s.cmd_depth, 0);
    @memset(&s.cmd_bits, 0);
    @memset(&s.cmd_histo, 0);

    for (literals) |lit| {
        s.lit_histo[lit] += 1;
    }
    compress_fragment.buildAndStoreHuffmanTreeFast(
        &s.tmp_tree,
        &s.lit_histo,
        literals.len,
        8,
        &s.lit_depth,
        &s.lit_bits,
        storage_ix,
        storage,
    );

    for (commands) |cmd| {
        const code = cmd & 0xFF;
        std.debug.assert(code < 128);
        s.cmd_histo[code] += 1;
    }
    s.cmd_histo[1] += 1;
    s.cmd_histo[2] += 1;
    s.cmd_histo[64] += 1;
    s.cmd_histo[84] += 1;
    buildAndStoreCommandPrefixCode(s, storage_ix, storage);

    var lit_idx: usize = 0;
    for (commands) |cmd| {
        const code = cmd & 0xFF;
        const extra = cmd >> 8;
        std.debug.assert(code < 128);
        bit_writer.writeBits(@intCast(s.cmd_depth[code]), s.cmd_bits[code], storage_ix, storage);
        bit_writer.writeBits(@intCast(kNumExtraBits[code]), extra, storage_ix, storage);
        if (code < 24) {
            const insert = kInsertOffset[code] + extra;
            var j: usize = 0;
            while (j < insert) : (j += 1) {
                const lit = literals[lit_idx];
                bit_writer.writeBits(@intCast(s.lit_depth[lit]), s.lit_bits[lit], storage_ix, storage);
                lit_idx += 1;
            }
        }
    }
}

fn createCommands(
    full_input: []const u8,
    input_offset: usize,
    block_size: usize,
    input_size: usize,
    base_ip: usize,
    table: []i32,
    table_bits: usize,
    min_match: usize,
    literal_buf: []u8,
    lit_idx: *usize,
    command_buf: []u32,
    cmd_idx: *usize,
) void {
    var ip = input_offset;
    const shift: u6 = @intCast(64 - table_bits);
    const ip_end = input_offset + block_size;
    var next_emit = input_offset;
    var last_distance: isize = -1;

    if (block_size >= BROTLI_WINDOW_GAP) {
        const len_limit = @min(block_size - min_match, input_size - BROTLI_WINDOW_GAP);
        const ip_limit = input_offset + len_limit;

        ip += 1;
        var next_hash = hash(full_input[ip..], shift, min_match);
        main_loop: while (true) {
            var skip: u32 = 32;
            var next_ip = ip;
            var candidate: usize = undefined;

            std.debug.assert(next_emit < ip);
            trawl: while (true) {
                while (true) {
                    const h = next_hash;
                    const bytes_between_hash_lookups = skip >> 5;
                    skip += 1;
                    ip = next_ip;
                    next_ip = ip + bytes_between_hash_lookups;
                    if (next_ip > ip_limit) {
                        break :main_loop;
                    }
                    next_hash = hash(full_input[next_ip..], shift, min_match);
                    if (last_distance >= 0 and @as(isize, @intCast(ip)) >= last_distance) {
                        candidate = @intCast(@as(isize, @intCast(ip)) - last_distance);
                        if (candidate < ip and isMatch(full_input[ip..], full_input[candidate..], min_match)) {
                            table[h] = @intCast(ip - base_ip);
                            break;
                        }
                    }
                    candidate = base_ip + @as(usize, @intCast(table[h]));
                    table[h] = @intCast(ip - base_ip);
                    if (isMatch(full_input[ip..], full_input[candidate..], min_match)) {
                        break;
                    }
                }

                if (ip - candidate > MAX_DISTANCE) continue :trawl;
                break;
            }

            {
                const base = ip;
                const matched = min_match + compress_fragment.findMatchLengthWithLimit(
                    full_input[candidate + min_match ..],
                    full_input[ip + min_match ..],
                    (ip_end - ip) - min_match,
                );
                const distance: isize = @intCast(base - candidate);
                const insert: u32 = @intCast(base - next_emit);
                ip += matched;

                emitInsertLen(insert, command_buf, cmd_idx);
                @memcpy(literal_buf[lit_idx.* .. lit_idx.* + insert], full_input[next_emit .. next_emit + insert]);
                lit_idx.* += insert;

                if (distance == last_distance) {
                    command_buf[cmd_idx.*] = 64;
                    cmd_idx.* += 1;
                } else {
                    emitDistance(@intCast(distance), command_buf, cmd_idx);
                    last_distance = distance;
                }
                emitCopyLenLastDistance(matched, command_buf, cmd_idx);

                next_emit = ip;
                if (ip >= ip_limit) {
                    break :main_loop;
                }

                {
                    var input_bytes: u64 = undefined;
                    var cur_hash: u32 = undefined;
                    var prev_h: u32 = undefined;
                    if (min_match == 4) {
                        input_bytes = std.mem.readInt(u64, full_input[ip - 3 ..][0..8], .little);
                        cur_hash = hashBytesAtOffset(input_bytes, 3, shift, min_match);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 3);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 2);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 1);
                    } else {
                        input_bytes = std.mem.readInt(u64, full_input[ip - 5 ..][0..8], .little);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 5);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 4);
                        prev_h = hashBytesAtOffset(input_bytes, 2, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 3);
                        input_bytes = std.mem.readInt(u64, full_input[ip - 2 ..][0..8], .little);
                        cur_hash = hashBytesAtOffset(input_bytes, 2, shift, min_match);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 2);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 1);
                    }

                    candidate = base_ip + @as(usize, @intCast(table[cur_hash]));
                    table[cur_hash] = @intCast(ip - base_ip);
                }
            }

            while (ip - candidate <= MAX_DISTANCE and isMatch(full_input[ip..], full_input[candidate..], min_match)) {
                const base = ip;
                const matched = min_match + compress_fragment.findMatchLengthWithLimit(
                    full_input[candidate + min_match ..],
                    full_input[ip + min_match ..],
                    (ip_end - ip) - min_match,
                );
                ip += matched;
                last_distance = @intCast(base - candidate);
                emitCopyLen(matched, command_buf, cmd_idx);
                emitDistance(@intCast(last_distance), command_buf, cmd_idx);

                next_emit = ip;
                if (ip >= ip_limit) {
                    break :main_loop;
                }
                {
                    var input_bytes: u64 = undefined;
                    var cur_hash: u32 = undefined;
                    var prev_h: u32 = undefined;
                    if (min_match == 4) {
                        input_bytes = std.mem.readInt(u64, full_input[ip - 3 ..][0..8], .little);
                        cur_hash = hashBytesAtOffset(input_bytes, 3, shift, min_match);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 3);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 2);
                        prev_h = hashBytesAtOffset(input_bytes, 2, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 1);
                    } else {
                        input_bytes = std.mem.readInt(u64, full_input[ip - 5 ..][0..8], .little);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 5);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 4);
                        prev_h = hashBytesAtOffset(input_bytes, 2, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 3);
                        input_bytes = std.mem.readInt(u64, full_input[ip - 2 ..][0..8], .little);
                        cur_hash = hashBytesAtOffset(input_bytes, 2, shift, min_match);
                        prev_h = hashBytesAtOffset(input_bytes, 0, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 2);
                        prev_h = hashBytesAtOffset(input_bytes, 1, shift, min_match);
                        table[prev_h] = @intCast(ip - base_ip - 1);
                    }

                    candidate = base_ip + @as(usize, @intCast(table[cur_hash]));
                    table[cur_hash] = @intCast(ip - base_ip);
                }
            }

            ip += 1;
            next_hash = hash(full_input[ip..], shift, min_match);
        }
    }

    // emit_remainder:
    if (next_emit < ip_end) {
        const insert: u32 = @intCast(ip_end - next_emit);
        emitInsertLen(insert, command_buf, cmd_idx);
        @memcpy(literal_buf[lit_idx.* .. lit_idx.* + insert], full_input[next_emit..ip_end]);
        lit_idx.* += insert;
    }
}

pub fn compressFragmentTwoPassImpl(
    s: *TwoPassArena,
    input: []const u8,
    is_last: bool,
    command_buf: []u32,
    literal_buf: []u8,
    table: []i32,
    table_bits: usize,
    min_match: usize,
    storage_ix: *usize,
    storage: []u8,
) void {
    _ = is_last;
    var input_offset: usize = 0;
    var input_size = input.len;
    const base_ip = 0;

    while (input_size > 0) {
        const block_size = @min(input_size, kCompressFragmentTwoPassBlockSize);
        var lit_idx: usize = 0;
        var cmd_idx: usize = 0;

        createCommands(
            input,
            input_offset,
            block_size,
            input_size,
            base_ip,
            table,
            table_bits,
            min_match,
            literal_buf,
            &lit_idx,
            command_buf,
            &cmd_idx,
        );

        const num_literals = lit_idx;
        const num_commands = cmd_idx;

        if (shouldCompress(s, input[input_offset .. input_offset + block_size], num_literals)) {
            storeMetaBlockHeader(block_size, false, storage_ix, storage);
            bit_writer.writeBits(13, 0, storage_ix, storage);
            storeCommands(
                s,
                literal_buf[0..num_literals],
                command_buf[0..num_commands],
                storage_ix,
                storage,
            );
        } else {
            emitUncompressedMetaBlock(input[input_offset .. input_offset + block_size], storage_ix, storage);
        }

        input_offset += block_size;
        input_size -= block_size;
    }
}

pub fn compressFragmentTwoPass(
    s: *TwoPassArena,
    input: []const u8,
    is_last: bool,
    command_buf: []u32,
    literal_buf: []u8,
    table: []i32,
    storage_ix: *usize,
    storage: []u8,
) void {
    const initial_storage_ix = storage_ix.*;
    const table_bits = std.math.log2_int(usize, table.len);
    const min_match: usize = if (table_bits <= 15) 4 else 6;

    if (input.len == 0) {
        if (is_last) {
            bit_writer.writeBits(1, 1, storage_ix, storage); // islast
            bit_writer.writeBits(1, 1, storage_ix, storage); // isempty
            storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
        }
        return;
    }

    compressFragmentTwoPassImpl(
        s,
        input,
        is_last,
        command_buf,
        literal_buf,
        table,
        table_bits,
        min_match,
        storage_ix,
        storage,
    );

    // If output is larger than single uncompressed block, rewrite it.
    if (storage_ix.* - initial_storage_ix > 31 + (input.len << 3)) {
        rewindBitPosition(initial_storage_ix, storage_ix, storage);
        emitUncompressedMetaBlock(input, storage_ix, storage);
    }

    if (is_last) {
        bit_writer.writeBits(1, 1, storage_ix, storage); // islast
        bit_writer.writeBits(1, 1, storage_ix, storage); // isempty
        storage_ix.* = (storage_ix.* + 7) & ~@as(usize, 7);
    }
}
