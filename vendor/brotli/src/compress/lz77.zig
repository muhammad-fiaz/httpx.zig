//! Greedy/lazy LZ77 backward-reference matcher.
//!
//! Hash-chain matcher over a contiguous buffer that begins with the retained
//! history of previously emitted blocks; produced commands follow the
//! format's ring-buffer semantics.

const std = @import("std");
const static_dict = @import("static_dict.zig");

pub const MIN_MATCH = 4;
/// Longest copy length the format's copy-length codes express (code 23 with
/// 24 extra bits on top of its base offset). Matches must never be capped
/// below this: a long run should become one copy command, not thousands.
pub const MAX_MATCH = (1 << 24) - 1;

/// Match profitability score: longer matches score higher, farther distances
/// score lower. Used for lazy-match decisions.
const SCORE_BASE: i64 = 1920;
const SCORE_MIN: i64 = SCORE_BASE + 100;
const SCORE_LAZY_DIFF: i64 = 175;

/// Last-distance bonus: a match at the most recent distance saves the
/// distance symbol entirely, worth about 15 bits over the plain score.
const SCORE_LAST_BONUS: i64 = 15;

fn matchScore(len: usize, dist: u32) i64 {
    if (dist == 0) return SCORE_MIN;
    const lb: u32 = std.math.log2_int(u32, dist);
    return SCORE_BASE + 135 * @as(i64, @intCast(len)) - 30 * @as(i64, @intCast(lb));
}

fn matchScoreLast(len: usize) i64 {
    return SCORE_BASE + 135 * @as(i64, @intCast(len)) + SCORE_LAST_BONUS;
}

/// A resolved built-in dictionary reference attached to a command.
pub const DictRef = struct {
    /// Base word length carried in the stream copy-length field.
    len_code: u32,
    /// Word index within its length class.
    word_idx: u16,
    /// RFC transform index into the shared transform table.
    transform_idx: u16,
};

pub const Command = struct {
    insert_len: u32,
    copy_len: u32,
    /// Absolute distance (1 = previous byte); zero for dict-only commands
    /// until assigned during planning.
    dist: u32 = 0,
    /// Present when this command copies from the built-in dictionary.
    dict: ?DictRef = null,
};

/// Recent-distance cache with the format's initial contents.
pub const DistRb = struct {
    rb: [4]u32 = .{ 16, 15, 11, 4 },
    idx: i32 = 0,

    pub fn last(self: *const DistRb) u32 {
        return self.rb[@intCast((self.idx -% 1) & 3)];
    }

    pub fn push(self: *DistRb, d: u32) void {
        self.rb[@intCast(self.idx & 3)] = d;
        self.idx +%= 1;
    }

    /// Short-code deltas for distance codes 4-15, one 4-bit entry per code.
    const SHORT_DELTA_TABLE: u32 = 0x605142;

    fn shortDelta(base: i32) i32 {
        const nibble = (SHORT_DELTA_TABLE >> @as(u5, @truncate(@as(u32, @bitCast(base)) *% 4))) & 0xF;
        return @as(i32, @intCast(nibble)) - 3;
    }

    /// Distance short code (0-15) that reproduces `d` under the current cache
    /// contents, if any. Pure: cache state is unchanged. The read uses the
    /// pre-adjustment index; the adjustment applies on use (see applyShort).
    pub fn shortCodeFor(self: *const DistRb, d: u32) ?u4 {
        var c: i32 = 0;
        while (c <= 3) : (c += 1) {
            const slot: u32 = @bitCast(self.idx -% (c -% 3));
            if (self.rb[slot & 3] == d) return @intCast(c);
        }
        c = 4;
        while (c <= 15) : (c += 1) {
            const index_delta: i32 = if (c < 10) 3 else 2;
            const base: i32 = if (c < 10) c - 4 else c - 10;
            const cand: i64 = @as(i64, self.rb[@as(u32, @bitCast(self.idx +% index_delta)) & 3]) + shortDelta(base);
            if (cand == d) return @intCast(c);
        }
        return null;
    }

    /// Advances cache state as if distance short `code` was used for a window
    /// copy: applies the read-side index adjustment, then records the copy
    /// distance.
    pub fn applyShort(self: *DistRb, code: u4, d: u32) void {
        if (code <= 3) {
            const ctx: i32 = @intCast((@as(u32, 1) >> @intCast(code)) & 1);
            self.idx -%= ctx;
        }
        self.push(d);
    }
};

pub const Params = struct {
    max_chain: u32 = 16,
    lazy: bool = true,
    min_match: usize = MIN_MATCH,
    /// Chain entries examined per position when collecting distinct-distance
    /// candidates. Each probe costs up to one full match comparison, so this
    /// multiplies directly by the typical match length; it is scaled by
    /// quality rather than left unbounded.
    probe_budget: u32 = 16,
    /// Distance-cache entries probed explicitly per position (0, 4, 10 or 16,
    /// following standard short-code distance checks). Cache entries
    /// are recent in use but possibly distant in position, so hash chains
    /// alone can bury them.
    num_cache_check: u32 = 4,
};

const HASH_BITS = 17;
const HASH_SIZE = 1 << HASH_BITS;

fn hash4(buf: []const u8, pos: usize) u32 {
    const v = std.mem.readInt(u32, buf[pos..][0..4], .little);
    return (v *% 0x1E35A7BD) >> @intCast(32 - HASH_BITS);
}

/// Number of leading bytes where `buf[a..]` and `buf[b..]` agree, capped at
/// `max`.
///
/// Match candidates on repetitive input routinely run for thousands of bytes,
/// so the comparison is done eight bytes at a time through `std.mem.readInt`,
/// which accepts unaligned slices. The first differing byte is recovered from
/// the XOR with a trailing-zero count, so the result is exactly the byte-wise
/// answer.
pub fn matchLenAt(buf: []const u8, a: usize, b: usize, max: usize) usize {
    const n = @min(max, buf.len - @max(a, b));
    var i: usize = 0;
    while (i + 8 <= n) {
        const x = std.mem.readInt(u64, buf[a + i ..][0..8], .little);
        const y = std.mem.readInt(u64, buf[b + i ..][0..8], .little);
        if (x != y) return i + (@ctz(x ^ y) >> 3);
        i += 8;
    }
    while (i < n and buf[a + i] == buf[b + i]) i += 1;
    return i;
}

/// One match alternative at a position.
pub const Candidate = struct {
    len: usize,
    dist: u32,
};

pub const MatchResult = struct {
    len: usize,
    dist: u32,
    /// Profitability score (last-distance bonus included when applicable);
    /// the lazy parser compares these directly.
    score: i64,
};

/// Finds the longest match at `pos` that stays inside `end`. Matches must never
/// cross the block boundary: `buf` can extend past `end` into the next block,
/// but a command produced here is serialized against this block alone.
/// Reusable hash-chain search over one buffer.
///
/// The greedy parser and the cost-based parser share this so both see exactly
/// the same candidate set for a position.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    buf: []const u8,
    head: []i64,
    prev: []i64,
    params: Params,

    pub fn init(allocator: std.mem.Allocator, buf: []const u8, params: Params) !Matcher {
        const head = try allocator.alloc(i64, HASH_SIZE);
        @memset(head, -1);
        const prev = try allocator.alloc(i64, buf.len);
        @memset(prev, -1);
        return .{ .allocator = allocator, .buf = buf, .head = head, .prev = prev, .params = params };
    }

    pub fn deinit(self: *Matcher) void {
        self.allocator.free(self.head);
        self.allocator.free(self.prev);
        self.* = undefined;
    }

    /// Chains every position before `start` so output positions can still reach
    /// back into retained history.
    pub fn primeHistory(self: *Matcher, start: usize) void {
        var h: usize = 0;
        while (h + self.params.min_match <= start) : (h += 1) self.insertAt(h);
    }

    pub fn insertAt(self: *Matcher, pos: usize) void {
        if (self.prev[pos] != -1) return;
        const h = hash4(self.buf, pos);
        self.prev[pos] = self.head[h];
        self.head[h] = @intCast(pos);
    }

    pub fn findAt(self: *const Matcher, pos: usize, end: usize, max_dist: usize, best_floor: usize) ?MatchResult {
        const empty = DistRb{};
        return findMatch(self.buf, pos, end, max_dist, self.head, self.prev, self.params, best_floor, &empty, 0);
    }

    /// Collects several distinct matches at `pos`, not just the longest.
    ///
    /// A long match is not always the cheapest: a slightly shorter one at a
    /// closer distance can cost fewer distance bits and leave a better
    /// downstream position. This walks the same chain as `findAt` but keeps
    /// the best match found for each distinct distance, then returns the
    /// strongest `out.len` of them. Candidates are ordered longest first so a
    /// caller can stop early once the remaining ones stop paying.
    ///
    /// Like `findAt`, every candidate stays inside `end`, so no match can cross
    /// a metablock boundary.
    pub fn findCandidates(
        self: *const Matcher,
        pos: usize,
        end: usize,
        max_dist: usize,
        out: []Candidate,
    ) usize {
        if (pos + self.params.min_match > end) return 0;

        const buf = self.buf;
        const cap = @min(end - pos, MAX_MATCH);
        const limit = @min(max_dist, pos);
        var found: usize = 0;

        // Longest length seen so far. Once a probe reaches `cap` no further
        // probe can beat it, so the chain walk stops. Without this a periodic
        // input spends `budget` probes per position each re-scanning a match
        // that is already maximally long.
        var best_len: usize = 0;

        var cand = self.head[hash4(buf, pos)];
        // Probe budget shared with the single-match search: without a cap a
        // popular bucket walks thousands of entries per position and the
        // optimal-parse sweep degrades quadratically on repetitive input.
        const budget = @min(self.params.max_chain, self.params.probe_budget);
        var probes: u32 = 0;
        while (cand >= 0) {
            const c: usize = @intCast(cand);
            if (c >= pos) break; // self-reference guard
            const dist = pos - c;
            if (dist > limit) break;

            const l = matchLenAt(buf, c, pos, cap);

            if (l >= self.params.min_match) {
                var slot: ?usize = null;
                var k: usize = 0;
                while (k < found) : (k += 1) {
                    if (out[k].dist == dist) {
                        slot = k;
                        break;
                    }
                }
                if (slot) |at| {
                    if (l > out[at].len) out[at] = .{ .len = l, .dist = @intCast(dist) };
                } else if (found < out.len) {
                    out[found] = .{ .len = l, .dist = @intCast(dist) };
                    found += 1;
                } else {
                    // Full: replace the weakest only if this one beats it.
                    var weakest: usize = 0;
                    var w: usize = 1;
                    while (w < found) : (w += 1) {
                        if (out[w].len < out[weakest].len) weakest = w;
                    }
                    if (l > out[weakest].len) out[weakest] = .{ .len = l, .dist = @intCast(dist) };
                }
                if (l > best_len) best_len = l;
            }

            // The candidate is recorded, so stopping here loses nothing: no
            // later probe can produce a match longer than `cap`.
            if (best_len >= cap) break;

            probes += 1;
            if (probes >= budget) break;
            cand = self.prev[c];
        }

        sortCandidates(out[0..found]);
        return found;
    }
};

/// Orders candidates longest first so callers can stop early.
fn sortCandidates(out: []Candidate) void {
    std.sort.insertion(Candidate, out, {}, lessLen);
}

fn lessLen(_: void, a: Candidate, b: Candidate) bool {
    return a.len > b.len;
}

/// Short-code delta table shared with the decoder-side cache semantics.
const CACHE_DELTA_TABLE: u32 = 0x605142;

/// Penalty (in score units) for using cache entry `i != 0` instead of the
/// most recent distance. Standard Brotli last-distance penalty.
fn cachePenalty(i: u32) i64 {
    return @as(i64, 39 + ((CACHE_DELTA_TABLE >> @as(u5, @intCast((i & 0xE)))) & 0xE));
}

/// Distance for cache probe `i` (short codes 0..15): entries 0..3 are the
/// last four distances, 4..9 the most recent +-1..3, 10..15 the second most
/// recent +-1..3. Returns 0 when the entry is not a usable distance.
/// This is the exact inverse of `DistRb.shortCodeFor`: the short code the
/// planner prices for a distance reproduces it through this table.
/// The cost-based parser uses it to generate cache-consistent candidates
/// the hash chains alone would never surface.
pub fn cacheEntry(cache: *const DistRb, i: u32) u32 {
    const at = struct {
        fn rec(c: *const DistRb, k: u32) i64 {
            return @as(i64, c.rb[@as(u32, @intCast((c.idx -% @as(i32, @intCast(k)) -% 1) & 3))]);
        }
    }.rec;
    const d: i64 = if (i < 4)
        at(cache, i)
    else if (i < 10)
        at(cache, 0) + ([_]i64{ -1, 1, -2, 2, -3, 3 })[i - 4]
    else
        at(cache, 1) + ([_]i64{ -1, 1, -2, 2, -3, 3 })[i - 10];
    if (d < 1) return 0;
    return @intCast(d);
}

fn findMatch(
    buf: []const u8,
    pos: usize,
    end: usize,
    max_dist: usize,
    head: []const i64,
    prev: []const i64,
    params: Params,
    best_floor: usize,
    cache: *const DistRb,
    num_cache_check: u32,
) ?MatchResult {
    if (pos + params.min_match > end) return null;
    const cap_total = @min(end - pos, MAX_MATCH);
    const limit = @min(max_dist, pos);
    var best_len: usize = best_floor;
    var best_dist: u32 = 0;
    var best_score: i64 = SCORE_MIN;
    // Explicit distance-cache probes first: cache entries are recent in use
    // but possibly distant in position, so hash chains alone can bury them.
    // The most recent distance keeps its reuse bonus; the rest pay the
    // standard short-code penalty.
    var ci: u32 = 0;
    while (ci < num_cache_check and ci < 16) : (ci += 1) {
        const dist = cacheEntry(cache, ci);
        if (dist == 0 or dist > limit or dist > pos) continue;
        const from = pos - dist;
        if (best_len >= 4 and pos + best_len < end and
            buf[from + best_len] != buf[pos + best_len])
        {
            continue;
        }
        const l = matchLenAt(buf, from, pos, cap_total);
        if (l >= params.min_match and l > best_len) {
            const score = SCORE_BASE + 135 * @as(i64, @intCast(l)) + (if (ci == 0) SCORE_LAST_BONUS else SCORE_LAST_BONUS - cachePenalty(ci));
            if (score > best_score) {
                best_len = l;
                best_dist = dist;
                best_score = score;
            }
        }
    }
    const h = hash4(buf, pos);
    var cand = head[h];
    var chain: u32 = 0;
    // Best score wins, not longest: a far-away long match can cost more than
    // the literals it saves. Candidates must also clear the acceptance floor.
    while (cand >= 0) {
        if (chain >= params.max_chain) break;
        const c: usize = @intCast(cand);
        if (c == pos or c >= pos) break; // self-reference guard
        const dist = pos - c;
        if (dist > limit) break;
        chain += 1;
        // Positional prune: the first `best_len` bytes are known to match
        // (same 4-byte hash seeds every chain entry, and longer bests were
        // verified), so a difference at offset `best_len` proves this probe
        // cannot beat the best. One byte compare saves a full scan.
        if (best_len >= 4 and pos + best_len < end and
            buf[c + best_len] != buf[pos + best_len])
        {
            cand = prev[c];
            continue;
        }
        const l = matchLenAt(buf, c, pos, cap_total);
        if (l > best_len) {
            const score = matchScore(l, @intCast(dist));
            if (score > best_score) {
                best_len = l;
                best_dist = @intCast(dist);
                best_score = score;
                // Nothing longer can be found at this position, so the chain walk
                // is finished. Bailing out here keeps the probe cost proportional
                // to the input rather than to the longest match.
                if (best_len >= cap_total) break;
            }
        }
        cand = prev[c];
    }
    if (best_dist == 0) return null;
    // Length floor gate for low-quality lookahead (must strictly improve).
    if (best_len <= best_floor) return null;
    return .{ .len = best_len, .dist = best_dist, .score = best_score };
}

fn insertHash(head: []i64, prev: []i64, buf: []const u8, pos: usize) void {
    if (prev[pos] != -1) return; // already chained
    const h = hash4(buf, pos);
    prev[pos] = head[h];
    head[h] = @intCast(pos);
}

/// Runs the matcher over `buf[start..]`, appending commands to `out`.
/// Trailing literals form a final copy-less command. When `lut` is provided,
/// positions may resolve into the built-in dictionary when that beats the
/// best in-window match.
pub fn compress(
    allocator: std.mem.Allocator,
    buf: []const u8,
    start: usize,
    end: usize,
    max_dist: usize,
    params: Params,
    out: *std.ArrayList(Command),
    lut: ?*const static_dict.Lut,
) !void {
    const head = try allocator.alloc(i64, HASH_SIZE);
    @memset(head, -1);
    defer allocator.free(head);
    const prev = try allocator.alloc(i64, buf.len);
    @memset(prev, -1);
    defer allocator.free(prev);

    // Pre-hash history (custom dictionary and/or prior blocks) so output
    // positions can form back-references into it.
    {
        var h: usize = 0;
        while (h + params.min_match <= start) : (h += 1) {
            insertHash(head, prev, buf, h);
        }
    }

    var pos = start;
    var lit_start = start;
    // Running distance cache for explicit cache probing, mirroring the
    // planner's update rules (implicit reuse leaves it, short codes adjust
    // it, other distances push). Dictionary references never touch it.
    var drb = DistRb{};

    while (pos < end) {
        if (pos + params.min_match > end) break;

        var m = findMatch(buf, pos, end, max_dist, head, prev, params, params.min_match - 1, &drb, params.num_cache_check);

        // Built-in dictionary fallback when the window found no match.
        if (m == null) {
            if (lut) |l| {
                if (static_dict.findBest(l, buf[pos..], params.min_match, @min(end - pos, MAX_MATCH))) |cand| {
                    if (cand.len >= 5) {
                        const stop = pos + cand.len;
                        var ip = pos;
                        while (ip < stop) : (ip += 1) {
                            if (ip + params.min_match <= end) insertHash(head, prev, buf, ip);
                        }
                        try out.append(allocator, .{
                            .insert_len = @intCast(pos - lit_start),
                            .copy_len = @intCast(cand.len),
                            .dist = 0,
                            .dict = .{
                                .len_code = @intCast(cand.len_code),
                                .word_idx = cand.word_idx,
                                .transform_idx = cand.transform_idx,
                            },
                        });
                        pos = stop;
                        lit_start = stop;
                        continue;
                    }
                }
            }
        }

        if (params.lazy and m != null) {
            // Multi-step lazy evaluation: defer the current match while the
            // next position offers a sufficiently better one (175 score
            // units, about 1.3 literal bytes). Up to four delays in a row.
            insertHash(head, prev, buf, pos);
            var cur_m = m.?;
            var cur_score = cur_m.score;
            var delays: u32 = 0;
            while (delays < 4 and pos + 1 + params.min_match <= end) {
                const m2 = findMatch(buf, pos + 1, end, max_dist, head, prev, params, params.min_match - 1, &drb, params.num_cache_check) orelse break;
                if (m2.score < cur_score + SCORE_LAZY_DIFF) break;
                pos += 1;
                insertHash(head, prev, buf, pos);
                cur_m = m2;
                cur_score = m2.score;
                m = cur_m;
                delays += 1;
                if (pos + 1 + params.min_match > end) break;
            }
            if (delays > 0) continue;
        }

        if (m == null) {
            insertHash(head, prev, buf, pos);
            pos += 1;
            continue;
        }

        const match = m.?;
        if (match.dist != 0) {
            if (match.dist == drb.last()) {
                // Implicit reuse: no cache change.
            } else if (drb.shortCodeFor(match.dist)) |code| {
                drb.applyShort(code, match.dist);
            } else {
                drb.push(match.dist);
            }
        }
        var ip = pos;
        // `findMatch` caps the length at the block end, so `stop <= end` holds
        // by construction and the command stream stays inside the block.
        const stop = pos + match.len;
        while (ip < stop) : (ip += 1) {
            if (ip + params.min_match <= end) insertHash(head, prev, buf, ip);
        }
        try out.append(allocator, .{
            .insert_len = @intCast(pos - lit_start),
            .copy_len = @intCast(match.len),
            .dist = match.dist,
        });
        pos = stop;
        lit_start = stop;
    }

    if (lit_start < end) {
        try out.append(allocator, .{
            .insert_len = @intCast(end - lit_start),
            .copy_len = 0,
            .dist = 0,
        });
    }
}
