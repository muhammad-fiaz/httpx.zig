//! HashLongestMatch hasher implementation (H5, H78, H85, H95).
//!
//! Multi-entry bucket hash tables for backward reference finding across Qualities 5 through 9.

const std = @import("std");
const hlmq = @import("hash_longest_match_quickly.zig");

pub fn HashLongestMatch(
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
        buckets: []u32,
        dict_num_lookups: usize = 0,
        dict_num_matches: usize = 0,
        hash_shift: u5 = @intCast(32 - BUCKET_BITS),

        pub fn init(num_buf: []u16, buckets_buf: []u32) Self {
            return .{
                .num = num_buf,
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
                    const key = hashBytes(data[i..], self.hash_shift);
                    self.num[key] = 0;
                }
            } else {
                @memset(self.num, 0);
            }
        }

        pub inline fn store(self: *Self, data: []const u8, mask: usize, ix: usize) void {
            const key = hashBytes(data[(ix & mask)..], self.hash_shift);
            const minor_ix = self.num[key] & BLOCK_MASK;
            const offset = minor_ix + (key << BLOCK_BITS);
            self.num[key] +%= 1;
            self.buckets[offset] = @intCast(ix);
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

            const key = hashBytes(data[cur_ix_masked..], self.hash_shift);
            const bucket = self.buckets[key << BLOCK_BITS .. (key << BLOCK_BITS) + BLOCK_SIZE];

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

            const num_k: usize = self.num[key];
            const down: usize = if (num_k > BLOCK_SIZE) num_k - BLOCK_SIZE else 0;
            var idx: usize = num_k;
            while (idx > down) {
                idx -= 1;
                const prev_ix_orig = bucket[idx & BLOCK_MASK];
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

            bucket[self.num[key] & BLOCK_MASK] = @intCast(cur_ix);
            self.num[key] +%= 1;

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

pub const H85 = HashLongestMatch(15, 7, 10);
pub const H95 = HashLongestMatch(15, 8, 16);
