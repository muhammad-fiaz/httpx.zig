//! Backward reference search (Quality 5-9).
//!
//! Evaluates LZ77 matches using lookahead greedy search and distance cache tracking.

const std = @import("std");
const hlmq = @import("hash_longest_match_quickly.zig");
const Command = hlmq.Command;
const HasherSearchResult = hlmq.HasherSearchResult;

pub fn createBackwardReferences(
    comptime HasherType: type,
    hasher: *HasherType,
    num_bytes: usize,
    position_in: usize,
    ringbuffer: []const u8,
    ringbuffer_mask: usize,
    quality: u32,
    lgwin: usize,
    position_offset: usize,
    num_direct_codes: usize,
    postfix_bits: usize,
    max_dist: usize,
    dist_cache: []i32,
    last_insert_len: *usize,
    commands: []Command,
    num_commands: *usize,
    num_literals: *usize,
) void {
    var position = position_in;
    const max_backward_limit = (@as(usize, 1) << @intCast(lgwin)) - 16;
    const gap: usize = 0;

    var insert_length = last_insert_len.*;
    const pos_end = position + num_bytes;
    const store_lookahead = HasherType.storeLookahead();
    const store_end = if (num_bytes >= store_lookahead)
        position + num_bytes - store_lookahead + 1
    else
        position;

    const random_heuristics_window_size: usize = if (quality < 9) 64 else 512;
    var apply_random_heuristics = position + random_heuristics_window_size;
    const kMinScore = hlmq.kMinScore;

    hasher.prepareDistanceCache(dist_cache);

    var cmd_idx = num_commands.*;

    while (position + HasherType.hashTypeLength() < pos_end) {
        var max_length = pos_end - position;
        var max_distance = @min(position, max_backward_limit);
        var dictionary_start = @min(position + position_offset, max_backward_limit);

        var sr = HasherSearchResult{};
        hasher.findLongestMatch(
            ringbuffer,
            ringbuffer_mask,
            dist_cache,
            position,
            max_length,
            max_distance,
            dictionary_start + gap,
            max_dist,
            &sr,
        );

        if (sr.score > kMinScore) {
            // Lazy evaluation: lookahead 1 byte
            var delayed_backward_references_in_row: i32 = 0;
            max_length -= 1;
            while (true) : (max_length -= 1) {
                const cost_diff_lazy: usize = 175;
                var sr2 = HasherSearchResult{};
                sr2.len = if (quality < 5)
                    @min(sr.len - 1, max_length)
                else
                    0;
                max_distance = @min(position + 1, max_backward_limit);
                dictionary_start = @min(position + 1 + position_offset, max_backward_limit);
                hasher.findLongestMatch(
                    ringbuffer,
                    ringbuffer_mask,
                    dist_cache,
                    position + 1,
                    max_length,
                    max_distance,
                    dictionary_start + gap,
                    max_dist,
                    &sr2,
                );
                if (sr2.score >= sr.score + cost_diff_lazy) {
                    position += 1;
                    insert_length += 1;
                    sr = sr2;
                    delayed_backward_references_in_row += 1;
                    if (delayed_backward_references_in_row < 4 and
                        position + HasherType.hashTypeLength() < pos_end)
                    {
                        continue;
                    }
                }
                break;
            }

            apply_random_heuristics = position + 2 * sr.len + random_heuristics_window_size;
            dictionary_start = @min(position + position_offset, max_backward_limit);
            {
                const distance_code = hlmq.computeDistanceCode(sr.distance, dictionary_start + gap, dist_cache);
                if (sr.distance <= (dictionary_start + gap) and distance_code > 0) {
                    dist_cache[3] = dist_cache[2];
                    dist_cache[2] = dist_cache[1];
                    dist_cache[1] = dist_cache[0];
                    dist_cache[0] = @intCast(sr.distance);
                    hasher.prepareDistanceCache(dist_cache);
                }
                commands[cmd_idx].init(
                    insert_length,
                    sr.len,
                    sr.len_code_delta,
                    distance_code,
                    num_direct_codes,
                    postfix_bits,
                );
                cmd_idx += 1;
            }
            num_literals.* += insert_length;
            insert_length = 0;

            {
                var range_start = position + 2;
                const range_end = @min(position + sr.len, store_end);
                if (sr.distance < (sr.len >> 2)) {
                    range_start = @min(
                        range_end,
                        @max(range_start, position + sr.len - (sr.distance << 2)),
                    );
                }
                hasher.storeRange(ringbuffer, ringbuffer_mask, range_start, range_end);
            }
            position += sr.len;
        } else {
            insert_length += 1;
            position += 1;
            if (position > apply_random_heuristics) {
                if (position > apply_random_heuristics + 4 * random_heuristics_window_size) {
                    const kMargin: usize = @max(HasherType.storeLookahead() - 1, 4);
                    const pos_jump = @min(position + 16, pos_end - kMargin);
                    while (position < pos_jump) : (position += 4) {
                        hasher.store(ringbuffer, ringbuffer_mask, position);
                        insert_length += 4;
                    }
                } else {
                    const kMargin: usize = @max(HasherType.storeLookahead() - 1, 2);
                    const pos_jump = @min(position + 8, pos_end - kMargin);
                    while (position < pos_jump) : (position += 2) {
                        hasher.store(ringbuffer, ringbuffer_mask, position);
                        insert_length += 2;
                    }
                }
            }
        }
    }

    insert_length += pos_end - position;
    last_insert_len.* = insert_length;
    num_commands.* = cmd_idx;
}
