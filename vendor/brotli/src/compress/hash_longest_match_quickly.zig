//! Hasher and command representation for fast backward references (H2, H3, H4).
//!
//! Provides single-bucket hash table matchers for Qualities 2, 3, and 4,
//! as well as RFC 7932 command structures and prefix encoding.

const std = @import("std");
const fast_log = @import("fast_log.zig");
const dictionary = @import("../dictionary/dictionary.zig");
const dictionary_hash = @import("dictionary_hash.zig");
const bit_writer = @import("../bitstream/bit_writer.zig");

pub const kHashMul32: u32 = 0x1E35A7BD;
pub const kHashMul64: u64 = 0x1FE35A7BD3579BD3;

pub const BROTLI_LITERAL_BYTE_SCORE: usize = 135;
pub const BROTLI_DISTANCE_BIT_PENALTY: usize = 30;
pub const BROTLI_SCORE_BASE: usize = 1920; // 30 * 8 * 8
pub const kMinScore: usize = BROTLI_SCORE_BASE + 100;

pub const kBrotliInsBase = [24]u32{
    0,  1,  2,  3,  4,   5,   6,   8,   10,   14,   18,   26,
    34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
};
pub const kBrotliInsExtra = [24]u32{
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
};
pub const kBrotliCopyBase = [24]u32{
    2,  3,  4,  5,  6,  7,   8,   9,   10,  12,  14,   18,
    22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118,
};
pub const kBrotliCopyExtra = [24]u32{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
};

pub inline fn getInsertLengthCode(insertlen: usize) u16 {
    if (insertlen < 6) {
        return @intCast(insertlen);
    } else if (insertlen < 130) {
        const nbits = fast_log.log2FloorNonZero(insertlen - 2) - 1;
        return @intCast((nbits << 1) + ((insertlen - 2) >> @intCast(nbits)) + 2);
    } else if (insertlen < 2114) {
        return @intCast(fast_log.log2FloorNonZero(insertlen - 66) + 10);
    } else if (insertlen < 6210) {
        return 21;
    } else if (insertlen < 22594) {
        return 22;
    } else {
        return 23;
    }
}

pub inline fn getCopyLengthCode(copylen: usize) u16 {
    if (copylen < 10) {
        return @intCast(copylen - 2);
    } else if (copylen < 134) {
        const nbits = fast_log.log2FloorNonZero(copylen - 6) - 1;
        return @intCast((nbits << 1) + ((copylen - 6) >> @intCast(nbits)) + 4);
    } else if (copylen < 2118) {
        return @intCast(fast_log.log2FloorNonZero(copylen - 70) + 12);
    } else {
        return 23;
    }
}

pub inline fn combineLengthCodes(inscode: u16, copycode: u16, use_last_distance: bool) u16 {
    const bits64: u16 = (copycode & 0x7) | ((inscode & 0x7) << 3);
    if (use_last_distance and inscode < 8 and copycode < 16) {
        return if (copycode < 8) bits64 else (bits64 | 64);
    } else {
        var offset: u32 = 2 * ((copycode >> 3) + 3 * (inscode >> 3));
        offset = (offset << 5) + 0x40 + ((@as(u32, 0x520D40) >> @intCast(offset)) & 0xC0);
        return @intCast(offset | bits64);
    }
}

pub inline fn getLengthCode(insertlen: usize, copylen: usize, use_last_distance: bool) u16 {
    const inscode = getInsertLengthCode(insertlen);
    const copycode = getCopyLengthCode(copylen);
    return combineLengthCodes(inscode, copycode, use_last_distance);
}

pub inline fn prefixEncodeCopyDistance(
    distance_code: usize,
    num_direct_codes: usize,
    postfix_bits: usize,
    code: *u16,
    extra_bits: *u32,
) void {
    if (distance_code < 16 + num_direct_codes) {
        code.* = @intCast(distance_code);
        extra_bits.* = 0;
    } else {
        const dist = (@as(usize, 1) << @intCast(postfix_bits + 2)) +
            (distance_code - 16 - num_direct_codes);
        const bucket = fast_log.log2FloorNonZero(dist) - 1;
        const postfix_mask = (@as(usize, 1) << @intCast(postfix_bits)) - 1;
        const postfix = dist & postfix_mask;
        const prefix = (dist >> @intCast(bucket)) & 1;
        const offset = (2 + prefix) << @intCast(bucket);
        const nbits = bucket - postfix_bits;
        code.* = @intCast((nbits << 10) |
            (16 + num_direct_codes +
                ((2 * (nbits - 1) + prefix) << @intCast(postfix_bits)) + postfix));
        extra_bits.* = @intCast((dist - offset) >> @intCast(postfix_bits));
    }
}

pub inline fn computeDistanceCode(
    distance: usize,
    max_distance: usize,
    dist_cache: []const i32,
) usize {
    if (distance <= max_distance) {
        const distance_plus_3 = distance + 3;
        const offset0 = distance_plus_3 -% @as(usize, @bitCast(@as(isize, dist_cache[0])));
        const offset1 = distance_plus_3 -% @as(usize, @bitCast(@as(isize, dist_cache[1])));
        if (distance == @as(usize, @bitCast(@as(isize, dist_cache[0])))) {
            return 0;
        } else if (distance == @as(usize, @bitCast(@as(isize, dist_cache[1])))) {
            return 1;
        } else if (offset0 < 7) {
            return (@as(u32, 0x9750468) >> @intCast(4 * offset0)) & 0xF;
        } else if (offset1 < 7) {
            return (@as(u32, 0xFDB1ACE) >> @intCast(4 * offset1)) & 0xF;
        } else if (distance == @as(usize, @bitCast(@as(isize, dist_cache[2])))) {
            return 2;
        } else if (distance == @as(usize, @bitCast(@as(isize, dist_cache[3])))) {
            return 3;
        }
    }
    return distance + 16 - 1;
}

pub const Command = struct {
    insert_len_: u32 = 0,
    copy_len_: u32 = 0,
    dist_extra_: u32 = 0,
    cmd_prefix_: u16 = 0,
    dist_prefix_: u16 = 0,

    pub inline fn copyLen(self: *const Command) u32 {
        return self.copy_len_ & 0x1FFFFFF;
    }

    pub inline fn copyLenCode(self: *const Command) u32 {
        const modifier: u8 = @truncate(self.copy_len_ >> 25);
        const delta: i8 = @bitCast(modifier | ((modifier & 0x40) << 1));
        return @intCast(@as(i32, @intCast(self.copy_len_ & 0x1FFFFFF)) + delta);
    }

    pub inline fn init(
        self: *Command,
        insertlen: usize,
        copylen: usize,
        copylen_code_delta: i32,
        distance_code: usize,
        num_direct_codes: usize,
        postfix_bits: usize,
    ) void {
        const delta = @as(u8, @bitCast(@as(i8, @intCast(copylen_code_delta))));
        self.insert_len_ = @intCast(insertlen);
        self.copy_len_ = @as(u32, @intCast(copylen)) | (@as(u32, delta & 0x7F) << 25);
        prefixEncodeCopyDistance(
            distance_code,
            num_direct_codes,
            postfix_bits,
            &self.dist_prefix_,
            &self.dist_extra_,
        );
        const copy_total: usize = @intCast(@as(i32, @intCast(copylen)) + copylen_code_delta);
        const use_last_distance = (self.dist_prefix_ & 0x3FF) == 0;
        self.cmd_prefix_ = getLengthCode(insertlen, copy_total, use_last_distance);
    }

    pub inline fn initInsert(self: *Command, insertlen: usize) void {
        self.insert_len_ = @intCast(insertlen);
        self.copy_len_ = 4 << 25;
        self.dist_extra_ = 0;
        self.dist_prefix_ = 16;
        self.cmd_prefix_ = getLengthCode(insertlen, 4, false);
    }
};

pub inline fn storeCommandExtra(cmd: *const Command, storage_ix: *usize, storage: []u8) void {
    const copylen_code = cmd.copyLenCode();
    const inscode = getInsertLengthCode(cmd.insert_len_);
    const copycode = getCopyLengthCode(copylen_code);
    const insnumextra = kBrotliInsExtra[inscode];
    const insextraval: u64 = cmd.insert_len_ - kBrotliInsBase[inscode];
    const copyextraval: u64 = copylen_code - kBrotliCopyBase[copycode];
    const bits = (copyextraval << @intCast(insnumextra)) | insextraval;
    bit_writer.writeBits(@intCast(insnumextra + kBrotliCopyExtra[copycode]), bits, storage_ix, storage);
}

pub inline fn backwardReferenceScore(copy_length: usize, backward_reference_offset: usize) usize {
    return BROTLI_SCORE_BASE + BROTLI_LITERAL_BYTE_SCORE * copy_length -
        BROTLI_DISTANCE_BIT_PENALTY * fast_log.log2FloorNonZero(backward_reference_offset);
}

pub inline fn backwardReferenceScoreUsingLastDistance(copy_length: usize) usize {
    return BROTLI_LITERAL_BYTE_SCORE * copy_length + BROTLI_SCORE_BASE + 15;
}

pub const HasherSearchResult = struct {
    len: usize = 0,
    distance: usize = 0,
    score: usize = kMinScore,
    len_code_delta: i32 = 0,
};

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

const cutoffTransformsCount: usize = 10;
const cutoffTransforms: u64 = 0x071B520ADA2D3200;

fn testStaticDictionaryItem(
    len: usize,
    word_idx: usize,
    data_slice: []const u8,
    max_length: usize,
    max_backward: usize,
    max_distance: usize,
    out: *HasherSearchResult,
) bool {
    const offset = dictionary.offsets_by_length[len] + len * word_idx;
    if (len > max_length) return false;
    const matchlen = findMatchLengthWithLimit(data_slice, dictionary.data[offset .. offset + len], len);
    if (matchlen + cutoffTransformsCount <= len or matchlen == 0) return false;
    const cut = len - matchlen;
    const transform_id = (cut << 2) + @as(usize, @intCast((cutoffTransforms >> @intCast(cut * 6)) & 0x3F));
    const backward = max_backward + 1 + word_idx + (transform_id << @intCast(dictionary.size_bits_by_length[len]));
    if (backward > max_distance) return false;
    const score = backwardReferenceScore(matchlen, backward);
    if (score < out.score) return false;
    out.len = matchlen;
    out.len_code_delta = @as(i32, @intCast(len)) - @as(i32, @intCast(matchlen));
    out.distance = backward;
    out.score = score;
    return true;
}

pub fn searchInStaticDictionary(
    dict_num_lookups: *usize,
    dict_num_matches: *usize,
    data_slice: []const u8,
    max_length: usize,
    max_backward: usize,
    max_distance: usize,
    out: *HasherSearchResult,
    shallow: bool,
) void {
    if (dict_num_matches.* < (dict_num_lookups.* >> 7)) return;
    const v = std.mem.readInt(u32, data_slice[0..4], .little);
    const h14 = (v *% 0x1E35A7BD) >> (32 - 14);
    var key = h14 << 1;
    const count: usize = if (shallow) 1 else 2;
    var i: usize = 0;
    while (i < count) : ({
        i += 1;
        key += 1;
    }) {
        dict_num_lookups.* += 1;
        const word_len = dictionary_hash.kStaticDictionaryHashLengths[key];
        if (word_len != 0) {
            const word_idx = dictionary_hash.kStaticDictionaryHashWords[key];
            if (testStaticDictionaryItem(word_len, word_idx, data_slice, max_length, max_backward, max_distance, out)) {
                dict_num_matches.* += 1;
            }
        }
    }
}

pub fn HashLongestMatchQuickly(
    comptime BUCKET_BITS: usize,
    comptime BUCKET_SWEEP_BITS: u3,
    comptime USE_DICTIONARY: bool,
) type {
    return struct {
        const Self = @This();
        pub const BUCKET_SIZE: usize = 1 << BUCKET_BITS;
        pub const BUCKET_MASK: usize = BUCKET_SIZE - 1;
        pub const BUCKET_SWEEP: usize = 1 << BUCKET_SWEEP_BITS;
        pub const BUCKET_SWEEP_MASK: usize = (BUCKET_SWEEP - 1) << 3;
        pub const HASH_LEN: usize = 5;

        buckets: []u32,
        dict_num_lookups: usize = 0,
        dict_num_matches: usize = 0,

        pub fn init(buckets: []u32) Self {
            std.debug.assert(buckets.len >= BUCKET_SIZE);
            return .{
                .buckets = buckets,
            };
        }

        pub inline fn hashTypeLength() usize {
            return 8;
        }

        pub inline fn storeLookahead() usize {
            return 8;
        }

        pub inline fn hashBytes(data: []const u8) u32 {
            const val = std.mem.readInt(u64, data[0..8], .little);
            const h = (val << (64 - 8 * HASH_LEN)) *% kHashMul64;
            return @truncate(h >> @as(u6, @intCast(64 - BUCKET_BITS)));
        }

        pub fn prepare(self: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            const partial_prepare_threshold = BUCKET_SIZE >> 5;
            if (one_shot and input_size <= partial_prepare_threshold) {
                var i: usize = 0;
                while (i < input_size) : (i += 1) {
                    const key = hashBytes(data[i..]);
                    if (BUCKET_SWEEP == 1) {
                        self.buckets[key] = 0;
                    } else {
                        var j: usize = 0;
                        while (j < BUCKET_SWEEP) : (j += 1) {
                            self.buckets[(key + (j << 3)) & BUCKET_MASK] = 0;
                        }
                    }
                }
            } else {
                @memset(self.buckets[0..BUCKET_SIZE], 0);
            }
        }

        pub inline fn store(self: *Self, data: []const u8, mask: usize, ix: usize) void {
            const key = hashBytes(data[(ix & mask)..]);
            if (BUCKET_SWEEP == 1) {
                self.buckets[key] = @intCast(ix);
            } else {
                const off = ix & BUCKET_SWEEP_MASK;
                self.buckets[(key + off) & BUCKET_MASK] = @intCast(ix);
            }
        }

        pub inline fn storeRange(self: *Self, data: []const u8, mask: usize, ix_start: usize, ix_end: usize) void {
            var i = ix_start;
            while (i < ix_end) : (i += 1) {
                self.store(data, mask, i);
            }
        }

        pub inline fn stitchToPreviousBlock(
            self: *Self,
            num_bytes: usize,
            position: usize,
            ringbuffer: []const u8,
            ringbuffer_mask: usize,
        ) void {
            if (num_bytes >= hashTypeLength() - 1 and position >= 3) {
                self.store(ringbuffer, ringbuffer_mask, position - 3);
                self.store(ringbuffer, ringbuffer_mask, position - 2);
                self.store(ringbuffer, ringbuffer_mask, position - 1);
            }
        }

        pub inline fn prepareDistanceCache(self: *Self, dist_cache: []i32) void {
            _ = self;
            _ = dist_cache;
        }

        pub fn findLongestMatch(
            self: *Self,
            data: []const u8,
            ring_buffer_mask: usize,
            dist_cache: []const i32,
            cur_ix: usize,
            max_length: usize,
            max_backward: usize,
            dictionary_distance: usize,
            max_distance: usize,
            out: *HasherSearchResult,
        ) void {
            const best_len_in = out.len;
            const cur_ix_masked = cur_ix & ring_buffer_mask;
            var compare_char = data[cur_ix_masked + best_len_in];
            const key = hashBytes(data[cur_ix_masked..]);
            var key_out: usize = undefined;
            const min_score = out.score;
            var best_score = out.score;
            var best_len = best_len_in;
            const cached_backward: usize = @intCast(dist_cache[0]);
            var prev_ix = cur_ix -% cached_backward;

            out.len_code_delta = 0;
            if (prev_ix < cur_ix) {
                prev_ix &= ring_buffer_mask;
                if (compare_char == data[prev_ix + best_len]) {
                    const len = findMatchLengthWithLimit(data[prev_ix..], data[cur_ix_masked..], max_length);
                    if (len >= 4) {
                        const score = backwardReferenceScoreUsingLastDistance(len);
                        if (best_score < score) {
                            out.len = len;
                            out.distance = cached_backward;
                            out.score = score;
                            if (BUCKET_SWEEP == 1) {
                                self.buckets[key] = @intCast(cur_ix);
                                return;
                            } else {
                                best_len = len;
                                best_score = score;
                                compare_char = data[cur_ix_masked + len];
                            }
                        }
                    }
                }
            }

            if (BUCKET_SWEEP == 1) {
                prev_ix = self.buckets[key];
                self.buckets[key] = @intCast(cur_ix);
                const backward = cur_ix - prev_ix;
                prev_ix &= ring_buffer_mask;
                if (compare_char != data[prev_ix + best_len_in]) {
                    return;
                }
                if (backward == 0 or backward > max_backward) {
                    return;
                }
                const len = findMatchLengthWithLimit(data[prev_ix..], data[cur_ix_masked..], max_length);
                if (len >= 4) {
                    const score = backwardReferenceScore(len, backward);
                    if (best_score < score) {
                        out.len = len;
                        out.distance = backward;
                        out.score = score;
                        return;
                    }
                }
            } else {
                var keys: [BUCKET_SWEEP]usize = undefined;
                var i: usize = 0;
                while (i < BUCKET_SWEEP) : (i += 1) {
                    keys[i] = (key + (i << 3)) & BUCKET_MASK;
                }
                key_out = keys[(cur_ix & BUCKET_SWEEP_MASK) >> 3];
                i = 0;
                while (i < BUCKET_SWEEP) : (i += 1) {
                    prev_ix = self.buckets[keys[i]];
                    const backward = cur_ix - prev_ix;
                    prev_ix &= ring_buffer_mask;
                    if (compare_char != data[prev_ix + best_len]) continue;
                    if (backward == 0 or backward > max_backward) continue;
                    const len = findMatchLengthWithLimit(data[prev_ix..], data[cur_ix_masked..], max_length);
                    if (len >= 4) {
                        const score = backwardReferenceScore(len, backward);
                        if (best_score < score) {
                            best_len = len;
                            out.len = len;
                            compare_char = data[cur_ix_masked + len];
                            best_score = score;
                            out.score = score;
                            out.distance = backward;
                        }
                    }
                }
            }

            if (USE_DICTIONARY and min_score == out.score) {
                searchInStaticDictionary(
                    &self.dict_num_lookups,
                    &self.dict_num_matches,
                    data[cur_ix_masked..],
                    max_length,
                    dictionary_distance,
                    max_distance,
                    out,
                    true,
                );
            }

            if (BUCKET_SWEEP != 1) {
                self.buckets[key_out] = @intCast(cur_ix);
            }
        }
    };
}

pub const H2 = HashLongestMatchQuickly(16, 0, true);
pub const H3 = HashLongestMatchQuickly(16, 1, false);
pub const H4 = HashLongestMatchQuickly(17, 2, true);
