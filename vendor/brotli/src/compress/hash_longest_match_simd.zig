//! HashLongestMatchSimd hasher implementation (H58, H68).
//!
//! SIMD-optimized multi-entry bucket hash tables with tag comparisons for Qualities 5 and 6.

const std = @import("std");
const hlmq = @import("hash_longest_match_quickly.zig");

pub fn HashLongestMatchSimd(
    comptime BUCKET_BITS: usize,
    comptime BLOCK_BITS: usize,
    comptime NUM_LAST_DISTANCES: usize,
) type {
    return struct {
        const Self = @This();

        pub const BUCKET_SIZE: usize = 1 << BUCKET_BITS;
        pub const BLOCK_SIZE: usize = 1 << BLOCK_BITS;
        pub const BLOCK_MASK: usize = BLOCK_SIZE - 1;
        pub const TOTAL_ENTRIES: usize = BUCKET_SIZE * BLOCK_SIZE;

        num: []u16,
        tags: []u8,
        buckets: []u32,
        dict_num_lookups: usize = 0,
        dict_num_matches: usize = 0,
        hash_shift: u5 = @intCast(32 - BUCKET_BITS - 8),

        pub fn init(num_buf: []u16, tags_buf: []u8, buckets_buf: []u32) Self {
            return .{
                .num = num_buf,
                .tags = tags_buf,
                .buckets = buckets_buf,
            };
        }

        pub inline fn hashTypeLength() usize {
            return 4;
        }

        pub inline fn storeLookahead() usize {
            return 4;
        }

        pub inline fn hashBytes(data: []const u8, shift: u5) u32 {
            const v = std.mem.readInt(u32, data[0..4], .little);
            return (v *% hlmq.kHashMul32) >> shift;
        }

        pub fn prepare(self: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            const partial_prepare_threshold = BUCKET_SIZE >> 6;
            if (one_shot and input_size <= partial_prepare_threshold) {
                for (0..input_size) |i| {
                    const hash = hashBytes(data[i..], self.hash_shift);
                    const key = hash >> 8;
                    self.num[key] = 65535;
                }
            } else {
                @memset(self.num, 65535);
            }
        }

        pub inline fn store(self: *Self, data: []const u8, mask: usize, ix: usize) void {
            const hash = hashBytes(data[(ix & mask)..], self.hash_shift);
            const key = hash >> 8;
            const tag: u8 = @truncate(hash & 0xFF);
            const minor_ix = self.num[key] & BLOCK_MASK;
            const offset = minor_ix + (key << BLOCK_BITS);
            self.num[key] -%= 1;
            self.buckets[offset] = @intCast(ix);
            self.tags[offset] = tag;
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

        pub inline fn prepareDistanceCache(self: *Self, distance_cache: []i32) void {
            _ = self;
            if (NUM_LAST_DISTANCES > 4 and distance_cache.len >= 10) {
                const last_distance = distance_cache[0];
                distance_cache[4] = last_distance - 1;
                distance_cache[5] = last_distance + 1;
                distance_cache[6] = last_distance - 2;
                distance_cache[7] = last_distance + 2;
                distance_cache[8] = last_distance - 3;
                distance_cache[9] = last_distance + 3;
                if (NUM_LAST_DISTANCES > 10 and distance_cache.len >= 16) {
                    const next_last_distance = distance_cache[1];
                    distance_cache[10] = next_last_distance - 1;
                    distance_cache[11] = next_last_distance + 1;
                    distance_cache[12] = next_last_distance - 2;
                    distance_cache[13] = next_last_distance + 2;
                    distance_cache[14] = next_last_distance - 3;
                    distance_cache[15] = next_last_distance + 3;
                }
            }
        }

        pub inline fn findLongestMatch(
            self: *Self,
            data: []const u8,
            ring_buffer_mask: usize,
            distance_cache: []const i32,
            cur_ix: usize,
            max_length: usize,
            max_backward: usize,
            dictionary_distance: usize,
            max_distance: usize,
            out: *hlmq.HasherSearchResult,
        ) void {
            const cur_ix_masked = cur_ix & ring_buffer_mask;
            const min_score = out.score;
            var best_score = out.score;
            var best_len = out.len;

            const hash = hashBytes(data[cur_ix_masked..], self.hash_shift);
            const key = hash >> 8;
            const bucket = self.buckets[key << BLOCK_BITS .. (key << BLOCK_BITS) + BLOCK_SIZE];
            const tag_bucket = self.tags[key << BLOCK_BITS .. (key << BLOCK_BITS) + BLOCK_SIZE];

            out.len = 0;
            out.len_code_delta = 0;

            // Try last distances first
            var i: usize = 0;
            while (i < NUM_LAST_DISTANCES and i < distance_cache.len) : (i += 1) {
                const dist_val = distance_cache[i];
                if (dist_val <= 0) continue;
                const backward: usize = @intCast(dist_val);
                if (backward > cur_ix) continue;
                const prev_ix_orig = cur_ix - backward;
                if (backward > max_backward) continue;
                const prev_ix = prev_ix_orig & ring_buffer_mask;

                if (cur_ix_masked + best_len > ring_buffer_mask) break;
                if (prev_ix + best_len > ring_buffer_mask or
                    data[cur_ix_masked + best_len] != data[prev_ix + best_len])
                {
                    continue;
                }
                const len = hlmq.findMatchLengthWithLimit(data[prev_ix..], data[cur_ix_masked..], max_length);
                if (len >= 3 or (len == 2 and i < 2)) {
                    var score = hlmq.backwardReferenceScoreUsingLastDistance(len);
                    if (best_score < score) {
                        if (i != 0) score -= (39 + ((@as(usize, 0x1CA10) >> @intCast(i & 0xE)) & 0xE));
                        if (best_score < score) {
                            best_score = score;
                            best_len = len;
                            out.len = best_len;
                            out.distance = backward;
                            out.score = best_score;
                        }
                    }
                }
            }

            if (best_len < 3) {
                best_len = 3;
            }

            const tag: u8 = @truncate(hash & 0xFF);
            const head: usize = (self.num[key] +% 1) & BLOCK_MASK;

            var matches: u64 = 0;
            if (BLOCK_SIZE == 16) {
                const tags_vec: @Vector(16, u8) = tag_bucket[0..16].*;
                const target_vec: @Vector(16, u8) = @splat(tag);
                const mask_val: u16 = @bitCast(tags_vec == target_vec);
                matches = std.math.rotr(u16, mask_val, @as(u4, @truncate(head)));
            } else if (BLOCK_SIZE == 32) {
                const tags_vec: @Vector(32, u8) = tag_bucket[0..32].*;
                const target_vec: @Vector(32, u8) = @splat(tag);
                const mask_val: u32 = @bitCast(tags_vec == target_vec);
                matches = std.math.rotr(u32, mask_val, @as(u5, @truncate(head)));
            } else if (BLOCK_SIZE == 64) {
                const tags_vec: @Vector(64, u8) = tag_bucket[0..64].*;
                const target_vec: @Vector(64, u8) = @splat(tag);
                const mask_val: u64 = @bitCast(tags_vec == target_vec);
                matches = std.math.rotr(u64, mask_val, @as(u6, @truncate(head)));
            } else {
                for (0..BLOCK_SIZE) |b_idx| {
                    if (tag_bucket[b_idx] == tag) {
                        matches |= (@as(u64, 1) << @intCast(b_idx));
                    }
                }
                matches = std.math.rotr(u64, matches, @as(u6, @truncate(head)));
            }

            const n: u16 = 65535 -% self.num[key];
            const block_has_unused_slots: u64 = if (BLOCK_SIZE > n) 1 else 0;
            const mask: u64 = (block_has_unused_slots << @intCast(n & 63)) -% 1;
            var m: u64 = matches & mask;

            while (m > 0) {
                const tz = @ctz(m);
                m &= m - 1;
                const rb_index = (head + tz) & BLOCK_MASK;
                const prev_ix_orig = bucket[rb_index];
                const backward = cur_ix - prev_ix_orig;
                if (backward > max_backward) break;
                const prev_ix = prev_ix_orig & ring_buffer_mask;

                if (cur_ix_masked + best_len > ring_buffer_mask) break;
                if (prev_ix + best_len > ring_buffer_mask) continue;

                if (std.mem.readInt(u32, data[cur_ix_masked + best_len - 3 ..][0..4], .little) !=
                    std.mem.readInt(u32, data[prev_ix + best_len - 3 ..][0..4], .little))
                {
                    continue;
                }
                const len = hlmq.findMatchLengthWithLimit(data[prev_ix..], data[cur_ix_masked..], max_length);
                if (len >= 4) {
                    const score = hlmq.backwardReferenceScore(len, backward);
                    if (best_score < score) {
                        best_score = score;
                        best_len = len;
                        out.len = best_len;
                        out.distance = backward;
                        out.score = best_score;
                    }
                }
            }

            const ins_pos = self.num[key] & BLOCK_MASK;
            bucket[ins_pos] = @intCast(cur_ix);
            tag_bucket[ins_pos] = tag;
            self.num[key] -%= 1;

            if (min_score == out.score) {
                hlmq.searchInStaticDictionary(
                    &self.dict_num_lookups,
                    &self.dict_num_matches,
                    data[cur_ix_masked..],
                    max_length,
                    dictionary_distance,
                    max_distance,
                    out,
                    false,
                );
            }
        }
    };
}

pub const H58 = HashLongestMatchSimd(14, 4, 4);
pub const H68 = HashLongestMatchSimd(14, 5, 4);
pub const H78 = HashLongestMatchSimd(15, 6, 10);
pub const H58_Q7 = H78;
