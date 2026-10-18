//! Static-dictionary word matching for the encoder.
//!
//! Builds a hash index over the embedded word list, including the
//! uppercase-first and uppercase-all variants, so the match finder can emit
//! dictionary references for text present in the built-in corpus.
//! Transform indices resolve through the shared 121-entry transform table.

const std = @import("std");
const dictionary = @import("../dictionary/dictionary.zig");
const transforms = @import("../common/transform.zig");
const tables = @import("../common/transform_table.zig");

pub const MAX_MATCH_LEN = 37;

/// Transform selector stored per index entry:
/// 0 = identity, 1 = uppercase first letter, 2 = uppercase all letters.
const T_IDENTITY: u8 = 0;
const T_UCFIRST: u8 = 1;
const T_UCALL: u8 = 2;

const DictWord = struct {
    /// Base word length (4..24).
    len: u8,
    /// T_IDENTITY / T_UCFIRST / T_UCALL.
    transform: u8,
    /// Word index within its length class.
    idx: u16,
};

const NUM_BUCKETS = 32768;

fn hash15(data: []const u8) u32 {
    const v = std.mem.readInt(u32, data[0..4], .little);
    return (v *% 0x1E35A7BD) >> (32 - 15);
}

/// Resolves the transform whose (prefix, type, suffix) triple matches, or
/// null when the combination is absent from the format table.
pub fn tIdOrNull(comptime pre: []const u8, comptime tt: transforms.TransformType, comptime suf: []const u8) ?u16 {
    @setEvalBranchQuota(200000);
    inline for (tables.transforms, 0..) |tr, i| {
        if (tr.type_id == @backingInt(tt) and
            std.mem.eql(u8, tables.prefixes_and_suffixes[tr.prefix_id], pre) and
            std.mem.eql(u8, tables.prefixes_and_suffixes[tr.suffix_id], suf))
        {
            return @intCast(i);
        }
    }
    return null;
}

/// Resolves a transform known to exist in the format table. `tt` must be
/// comptime-known; runtime callers use the uppercase branch below.
pub fn tId(comptime pre: []const u8, comptime tt: transforms.TransformType, comptime suf: []const u8) u16 {
    return tIdOrNull(pre, tt, suf).?;
}

fn upperBaseId(is_all: bool) u16 {
    return if (is_all)
        tIdOrNull("", .uppercase_all, "").?
    else
        tIdOrNull("", .uppercase_first, "").?;
}

pub const Lut = struct {
    heads: [NUM_BUCKETS]u32 = @splat(0),
    words: []DictWord = &.{},
    prev: []u32 = &.{},
    // Original allocation sizes; slices above are truncated views.
    words_cap: usize = 0,
    prev_cap: usize = 0,

    // Upper bound: identity plus two case variants per word.
    pub const max_entries: usize = blk: {
        var total: usize = 0;
        var len: u32 = dictionary.min_word_length;
        while (len <= dictionary.max_word_length) : (len += 1)
            total += dictionary.numWordsByLength(len);
        break :blk total * 3;
    };

    fn add(self: *Lut, n: *usize, w: DictWord) void {
        const key = keyOf(w);
        self.words[n.*] = w;
        self.prev[n.*] = self.heads[key];
        self.heads[key] = @intCast(n.* + 1);
        n.* += 1;
    }

    pub fn build(allocator: std.mem.Allocator) !Lut {
        var self = Lut{};
        self.words = try allocator.alloc(DictWord, max_entries);
        self.words_cap = max_entries;
        errdefer allocator.free(self.words);
        self.prev = try allocator.alloc(u32, max_entries);
        self.prev_cap = max_entries;
        errdefer allocator.free(self.prev);
        var n: usize = 0;

        var len: usize = dictionary.min_word_length;
        while (len <= dictionary.max_word_length) : (len += 1) {
            const num_words = dictionary.numWordsByLength(@intCast(len));
            const base = dictionary.offsets_by_length[@intCast(len)];
            var i: u32 = 0;
            while (i < num_words) : (i += 1) {
                const word = dictionary.data[base + i * len ..][0..len];

                self.add(&n, .{ .len = @intCast(len), .transform = T_IDENTITY, .idx = @intCast(i) });

                if (std.ascii.isLower(word[0])) {
                    var buf: [24]u8 = undefined;
                    @memcpy(buf[0..len], word);
                    buf[0] = std.ascii.toUpper(buf[0]);
                    if (!self.hasIdentityWord(buf[0..len])) {
                        self.add(&n, .{ .len = @intCast(len), .transform = T_UCFIRST, .idx = @intCast(i) });
                    }
                }

                var has_lower = false;
                var is_ascii = true;
                for (word) |c| {
                    if (std.ascii.isLower(c)) {
                        has_lower = true;
                    } else if (c < 0x20 or c > 0x7e) {
                        is_ascii = false;
                        break;
                    }
                }
                if (is_ascii and has_lower) {
                    var buf: [24]u8 = undefined;
                    for (word, 0..) |c, k| {
                        buf[k] = std.ascii.toUpper(c);
                    }
                    if (!self.hasIdentityWord(buf[0..len])) {
                        self.add(&n, .{ .len = @intCast(len), .transform = T_UCALL, .idx = @intCast(i) });
                    }
                }
            }
        }

        self.words = self.words[0..n];
        self.prev = self.prev[0..n];
        return self;
    }

    fn keyOf(w: DictWord) u32 {
        const base = dictionary.offsets_by_length[w.len] +
            @as(u32, w.len) * @as(u32, w.idx);
        const raw = dictionary.data[base..][0..w.len];
        switch (w.transform) {
            T_UCFIRST => {
                if (std.ascii.isLower(raw[0])) {
                    var buf: [4]u8 = undefined;
                    @memcpy(&buf, raw[0..4]);
                    buf[0] = std.ascii.toUpper(buf[0]);
                    return hash15(&buf);
                }
                return hash15(raw);
            },
            T_UCALL => {
                var buf: [4]u8 = undefined;
                @memcpy(&buf, raw[0..4]);
                for (&buf) |*c| {
                    c.* = std.ascii.toUpper(c.*);
                }
                return hash15(&buf);
            },
            else => return hash15(raw),
        }
    }

    fn hasIdentityWord(self: *const Lut, transformed: []const u8) bool {
        const key = hash15(transformed[0..4]);
        var cur = self.heads[key];
        while (cur != 0) {
            const w = self.words[cur - 1];
            cur = self.prev[cur - 1];
            if (w.transform != T_IDENTITY or w.len != transformed.len) continue;
            const base = dictionary.offsets_by_length[w.len] +
                @as(u32, w.len) * @as(u32, w.idx);
            if (std.mem.eql(u8, dictionary.data[base..][0..w.len], transformed)) return true;
        }
        return false;
    }

    pub fn deinit(self: *Lut, allocator: std.mem.Allocator) void {
        if (self.words_cap != 0) allocator.free(self.words.ptr[0..self.words_cap]);
        if (self.prev_cap != 0) allocator.free(self.prev.ptr[0..self.prev_cap]);
        self.* = .{};
    }
};

pub const Candidate = struct {
    /// Transformed output length (actual bytes produced).
    len: usize,
    /// Base word length carried in the stream's copy-length field.
    len_code: usize,
    /// Word index within its length class.
    word_idx: u16,
    /// RFC transform index into the shared 121-entry table.
    transform_idx: u16,
};

fn dictMatchLength(word: []const u8, data: []const u8, maxlen: usize) usize {
    var l: usize = 0;
    const cap = @min(word.len, maxlen);
    while (l < cap and word[l] == data[l]) l += 1;
    return l;
}

fn isMatchUpper(raw: []const u8, data: []const u8, transform: u8) bool {
    switch (transform) {
        T_UCFIRST => {
            if (!std.ascii.isLower(raw[0])) return false;
            if (std.ascii.toUpper(raw[0]) != data[0]) return false;
            return dictMatchLength(raw[1..], data[1..], raw.len - 1) == raw.len - 1;
        },
        else => {
            for (raw, 0..) |c, i| {
                const want = std.ascii.toUpper(c);
                if (want != data[i]) return false;
            }
            return true;
        },
    }
}

const Best = struct {
    cand: ?Candidate = null,

    fn offer(
        self: *Best,
        out_len: usize,
        len_code: usize,
        word_idx: u16,
        tid: u16,
        min_len: usize,
        max_len: usize,
    ) void {
        if (out_len > max_len or out_len < min_len) return;
        if (out_len < dictionary.min_word_length) return;
        const c = Candidate{
            .len = out_len,
            .len_code = len_code,
            .word_idx = word_idx,
            .transform_idx = tid,
        };
        const cur = self.cand orelse {
            self.cand = c;
            return;
        };
        if (c.len > cur.len) {
            self.cand = c;
            return;
        }
        if (c.len < cur.len) return;
        // Tie-break: cheaper base length coding, then smaller address parts.
        if (c.len_code < cur.len_code or
            (c.len_code == cur.len_code and
                (@as(u32, c.transform_idx) * 4096 + c.word_idx) <
                    (@as(u32, cur.transform_idx) * 4096 + cur.word_idx)))
        {
            self.cand = c;
        }
    }
};

fn offerResolved(
    b: *Best,
    l: usize,
    word_idx: u16,
    s: []const u8,
    min_len: usize,
    max_len: usize,
    suf: []const u8,
    tid: u16,
) void {
    if (s.len >= suf.len and std.mem.eql(u8, s[0..suf.len], suf)) {
        b.offer(l + suf.len, l, word_idx, tid, min_len, max_len);
    }
}

/// Finds the strongest static-dictionary reference at `data`.
/// Preference: longest transformed output, cheapest base length, smallest
/// address. Returns null when nothing matches within bounds.
pub fn findBest(
    lut: *const Lut,
    data: []const u8,
    min_len: usize,
    max_len: usize,
) ?Candidate {
    if (data.len < 4 or max_len < dictionary.min_word_length) return null;

    var b = Best{};

    const key = hash15(data);
    var cur = lut.heads[key];
    while (cur != 0) {
        const w = lut.words[cur - 1];
        cur = lut.prev[cur - 1];

        const l: usize = w.len;
        // Effective byte budget available at this position.
        const avail = @min(max_len, data.len);
        if (l > avail) continue;
        const base = dictionary.offsets_by_length[w.len] +
            @as(u32, w.len) * @as(u32, w.idx);
        const raw = dictionary.data[base..][0..l];

        if (w.transform == T_IDENTITY) {
            const matchlen = dictMatchLength(raw, data, avail);

            // Base word.
            if (matchlen == l) b.offer(l, l, w.idx, IDENTITY_EMPTY, min_len, max_len);

            // Omit last letter; optionally followed by "ing ".
            if (matchlen >= l - 1 and l >= 5) {
                if (OMIT1_EMPTY) |tid| b.offer(l - 1, l, w.idx, tid, min_len, max_len);
                if (data.len > l + 2 and
                    data[l - 1] == 'i' and data[l] == 'n' and data[l + 1] == 'g' and data[l + 2] == ' ')
                {
                    if (OMIT1_ING) |tid| b.offer(l + 3, l, w.idx, tid, min_len, max_len);
                }
            }

            // Omit-last-N for N in 2..9.
            if (matchlen >= 2) {
                var cut: usize = 2;
                while (cut <= 9 and cut < l) : (cut += 1) {
                    const out_len = l - cut;
                    if (matchlen < out_len) break;
                    if (cutoffIds[cut]) |tid| b.offer(out_len, l, w.idx, tid, min_len, max_len);
                }
            }

            if (matchlen < l or l + 6 >= data.len) continue;
            const s = data[l..];

            inline for (identity_space_ids) |pair| {
                offerResolved(&b, l, w.idx, s, min_len, max_len, pair.suf, pair.id);
            }
            inline for (identity_punct_ids) |pair| {
                offerResolved(&b, l, w.idx, s, min_len, max_len, pair.suf, pair.id);
            }
        } else {
            if (!isMatchUpper(raw, data, w.transform)) continue;
            const is_all = w.transform == T_UCALL;
            b.offer(l, l, w.idx, upperBaseId(is_all), min_len, max_len);
            if (l + 1 >= data.len) continue;
            const s = data[l..];
            if (is_all) {
                inline for (upper_ids_all) |pair| {
                    offerResolved(&b, l, w.idx, s, min_len, max_len, pair.suf, pair.id);
                }
            } else {
                inline for (upper_ids_first) |pair| {
                    offerResolved(&b, l, w.idx, s, min_len, max_len, pair.suf, pair.id);
                }
            }
        }
    }

    return b.cand;
}

// Comptime-resolved transform indices used by the matcher.

const IDENTITY_EMPTY: u16 = tId("", .identity, "");
const OMIT1_EMPTY: ?u16 = tIdOrNull("", .omit_last_1, "");
const OMIT1_ING: ?u16 = tIdOrNull("", .omit_last_1, "ing ");

/// Packed "" + OMIT_LAST_N + "" ids for N in 2..9 (index = N).
const cutoffIds: [10]?u16 = blk: {
    @setEvalBranchQuota(100000);
    var ids: [10]?u16 = @splat(null);
    var n: u32 = 2;
    while (n <= 9) : (n += 1) {
        const tt: transforms.TransformType = @fromBackingInt(@intCast(@as(u8, @intCast(n))));
        ids[n] = tIdOrNull("", tt, "");
    }
    break :blk ids;
};

const identity_space_suffixes = [_][]const u8{
    " ",     "a ",    "as ", "at ", "and ", "by ",  "in ",   "is ",
    "for ",  "from ", "of ", "on ", "not ", "the ", "that ", "to ",
    "with ",
};
const identity_punct_suffixes = [_][]const u8{
    "\"",  "\">",  ".",    ". ",   ". The ", ". This ",
    ",",   ", ",   "\n",   "\n\t", "]",      "'",
    ":",   "(",    "=\"",  "='",   "al ",    "ed ",
    "er ", "est ", "ful ", "ive ", "ize ",   "less ",
    "ly ", "ous ",
};
const upper_suffixes = [_][]const u8{
    " ", "\"", "\">", ".", ". ", ",", ", ", "'", "(",
};

const SuffixId = struct { suf: []const u8, id: u16 };

fn resolvePairs(comptime tt: transforms.TransformType, comptime suffixes: []const []const u8) []const SuffixId {
    @setEvalBranchQuota(300000);
    var out: [suffixes.len]SuffixId = undefined;
    var n: usize = 0;
    for (suffixes) |suf| {
        if (tIdOrNull("", tt, suf)) |id| {
            out[n] = .{ .suf = suf, .id = id };
            n += 1;
        }
    }
    const fixed: [n]SuffixId = out[0..n].*;
    return &fixed;
}

const identity_space_ids = resolvePairs(.identity, &identity_space_suffixes);
const identity_punct_ids = resolvePairs(.identity, &identity_punct_suffixes);
const upper_ids_first = resolvePairs(.uppercase_first, &upper_suffixes);
const upper_ids_all = resolvePairs(.uppercase_all, &upper_suffixes);

// Tests

const testing = std.testing;

fn wordFor(c: Candidate) []const u8 {
    const base = dictionary.offsets_by_length[c.len_code] +
        @as(u32, @intCast(c.len_code)) * c.word_idx;
    return dictionary.data[base..][0..c.len_code];
}

test "lut builds and finds plain dictionary words" {
    var lut = try Lut.build(testing.allocator);
    defer lut.deinit(testing.allocator);

    // The corpus's first four-letter word is "time"; followed by a space it
    // resolves through "" + IDENTITY + " " for a five-byte reference.
    const c = findBest(&lut, "time on network", 4, 37).?;
    try testing.expectEqual(@as(usize, 5), c.len);
    try testing.expectEqualStrings("time", wordFor(c));
}

test "lut finds uppercase-all variants" {
    var lut = try Lut.build(testing.allocator);
    defer lut.deinit(testing.allocator);

    // Take any lowercase six-letter corpus word and query its full-caps form.
    var src: []const u8 = &.{};
    const base = dictionary.offsets_by_length[6];
    var wi: u32 = 0;
    while (wi < dictionary.numWordsByLength(6)) : (wi += 1) {
        const w = dictionary.data[base + wi * 6 ..][0..6];
        var lower = true;
        for (w) |ch| {
            if (!std.ascii.isLower(ch)) {
                lower = false;
                break;
            }
        }
        if (lower) {
            src = w;
            break;
        }
    }
    try testing.expect(src.len != 0);
    var upper: [6]u8 = undefined;
    for (src, 0..) |ch, k| upper[k] = std.ascii.toUpper(ch);

    const c = findBest(&lut, &upper, 4, 37).?;
    try testing.expectEqual(src.len, c.len);
    var buf: [MAX_MATCH_LEN]u8 = undefined;
    const produced = transforms.transformDictionaryWord(&buf, wordFor(c), c.transform_idx);
    try testing.expectEqualSlices(u8, &upper, buf[0..produced]);
}

test "cutoff table entries exist for omit-last forms" {
    try testing.expectEqual(@as(u16, 0), IDENTITY_EMPTY);
    try testing.expect(OMIT1_EMPTY != null);
    var n: usize = 2;
    while (n <= 9) : (n += 1) try testing.expect(cutoffIds[n] != null);
}
