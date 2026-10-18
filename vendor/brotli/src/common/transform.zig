//! RFC 7932 word transforms; table data generated mechanically from the
//! format specification.

const std = @import("std");
const tables = @import("transform_table.zig");

pub const TransformType = enum(u8) {
    identity = 0,
    omit_last_1 = 1,
    omit_last_2 = 2,
    omit_last_3 = 3,
    omit_last_4 = 4,
    omit_last_5 = 5,
    omit_last_6 = 6,
    omit_last_7 = 7,
    omit_last_8 = 8,
    omit_last_9 = 9,
    uppercase_first = 10,
    uppercase_all = 11,
    omit_first_1 = 12,
    omit_first_2 = 13,
    omit_first_3 = 14,
    omit_first_4 = 15,
    omit_first_5 = 16,
    omit_first_6 = 17,
    omit_first_7 = 18,
    omit_first_8 = 19,
    omit_first_9 = 20,
    shift_first = 21,
    shift_all = 22,
};

pub const MAX_CUT_OFF = @backingInt(TransformType.omit_last_9);

/// RFC 7932 transforms string data: length-prefixed strings.
pub const prefix_suffix = tables.prefix_suffix;
/// Offsets of the length-prefixed strings within `prefix_suffix`.
pub const prefix_suffix_map = tables.prefix_suffix_map;
/// Each transform is a [prefix_id, type, suffix_id] triplet.
pub const transforms_data = tables.transforms_data;
pub const num_transforms = tables.num_transforms;
/// Indices of transforms like ["", OMIT_LAST_#, ""]; the 0-th element
/// corresponds to ["", IDENTITY, ""].
pub const cut_off_transforms = tables.cut_off_transforms;

inline fn prefixId(i: usize) u8 {
    return tables.transforms[i].prefix_id;
}
inline fn typeOf(i: usize) TransformType {
    return @fromBackingInt(@intCast(tables.transforms[i].type_id));
}
inline fn suffixId(i: usize) u8 {
    return tables.transforms[i].suffix_id;
}

pub inline fn prefixOf(transform_idx: usize) []const u8 {
    return tables.prefixes_and_suffixes[tables.transforms[transform_idx].prefix_id];
}

pub inline fn suffixOf(transform_idx: usize) []const u8 {
    return tables.prefixes_and_suffixes[tables.transforms[transform_idx].suffix_id];
}

fn toUpperCase(p: []u8) usize {
    if (p[0] < 0xC0) {
        p[0] = std.ascii.toUpper(p[0]);
        return 1;
    }
    // An overly simplified uppercasing model for UTF-8.
    if (p[0] < 0xE0) {
        p[1] ^= 32;
        return 2;
    }
    // An arbitrary transform for three byte characters.
    p[2] ^= 5;
    return 3;
}

fn shiftBytes(word: []u8, parameter: u16) usize {
    // Limited sign extension: scalar < (1 << 24).
    var scalar: u32 =
        @as(u32, parameter & 0x7FFF) +% (0x1000000 -% (@as(u32, parameter & 0x8000)));
    const w0 = word[0];
    if (w0 < 0x80) {
        scalar += w0;
        word[0] = @intCast(scalar & 0x7F);
        return 1;
    } else if (w0 < 0xC0) {
        // Continuation / 10AAAAAA.
        return 1;
    } else if (w0 < 0xE0) {
        if (word.len < 2) return 1;
        scalar += (@as(u32, word[1] & 0x3F) | ((@as(u32, w0) & 0x1F) << 6));
        word[0] = @intCast(0xC0 | ((scalar >> 6) & 0x1F));
        word[1] = (word[1] & 0xC0) | @as(u8, @intCast(scalar & 0x3F));
        return 2;
    } else if (w0 < 0xF0) {
        if (word.len < 3) return word.len;
        scalar += (@as(u32, word[2] & 0x3F) | ((@as(u32, word[1]) & 0x3F) << 6) |
            ((@as(u32, w0) & 0x0F) << 12));
        word[0] = @intCast(0xE0 | ((scalar >> 12) & 0x0F));
        word[1] = (word[1] & 0xC0) | @as(u8, @intCast((scalar >> 6) & 0x3F));
        word[2] = (word[2] & 0xC0) | @as(u8, @intCast(scalar & 0x3F));
        return 3;
    } else if (w0 < 0xF8) {
        if (word.len < 4) return word.len;
        scalar += (@as(u32, word[3] & 0x3F) | ((@as(u32, word[2]) & 0x3F) << 6) |
            ((@as(u32, word[1]) & 0x3F) << 12) | ((@as(u32, w0) & 0x07) << 18));
        word[0] = @intCast(0xF0 | ((scalar >> 18) & 0x07));
        word[1] = (word[1] & 0xC0) | @as(u8, @intCast((scalar >> 12) & 0x3F));
        word[2] = (word[2] & 0xC0) | @as(u8, @intCast((scalar >> 6) & 0x3F));
        word[3] = (word[3] & 0xC0) | @as(u8, @intCast(scalar & 0x3F));
        return 4;
    }
    return 1;
}

/// Applies the `transform_idx`-th RFC transform to a dictionary word.
/// Returns the number of bytes written to `dst`, which must be at least
/// 255 + 24 + 255 bytes long.
pub fn transformDictionaryWord(
    dst: []u8,
    word: []const u8,
    transform_idx: usize,
) usize {
    var idx: usize = 0;
    const tr = tables.transforms[transform_idx];
    const t: TransformType = @fromBackingInt(@intCast(tr.type_id));
    const ti = tr.type_id;
    var wlen: i32 = @intCast(word.len);
    // Prefix copy.
    const pre = tables.prefixes_and_suffixes[tr.prefix_id];
    @memcpy(dst[idx .. idx + pre.len], pre);
    idx += pre.len;
    // Word copy with omission.
    var wi: usize = 0;
    if (ti <= @backingInt(TransformType.omit_last_9)) {
        wlen -= @intCast(ti);
    } else if (ti >= @backingInt(TransformType.omit_first_1) and
        ti <= @backingInt(TransformType.omit_first_9))
    {
        const skip: usize = ti - (@backingInt(TransformType.omit_first_1) - 1);
        wi += skip;
        wlen -= @intCast(skip);
    }
    if (wlen > 0) {
        const copy_len: usize = @intCast(wlen);
        @memcpy(dst[idx .. idx + copy_len], word[wi .. wi + copy_len]);
        idx += copy_len;
    }
    // In-place post-processing of the copied word.
    const start = idx - @as(usize, @intCast(@max(wlen, 0)));
    const tail = dst[start..idx];
    switch (t) {
        .uppercase_first => {
            if (tail.len > 0) _ = toUpperCase(tail);
        },
        .uppercase_all => {
            var pos: usize = 0;
            var remaining: i32 = wlen;
            while (remaining > 0) {
                const step = toUpperCase(tail[pos..]);
                pos += step;
                remaining -= @intCast(step);
            }
        },
        .shift_first, .shift_all => unreachable, // not present in RFC transforms
        else => {},
    }
    // Suffix copy.
    const suf = tables.prefixes_and_suffixes[tr.suffix_id];
    @memcpy(dst[idx .. idx + suf.len], suf);
    idx += suf.len;
    return idx;
}

test "identity keeps the word" {
    var buf: [512]u8 = undefined;
    const n = transformDictionaryWord(&buf, "hello", 0);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "identity with suffix" {
    var buf: [512]u8 = undefined;
    // Transform 1: "" + IDENTITY + " ".
    const n = transformDictionaryWord(&buf, "hello", 1);
    try std.testing.expectEqualStrings("hello ", buf[0..n]);
}

test "uppercase first" {
    var buf: [512]u8 = undefined;
    // Index 9: "", UPPERCASE_FIRST, "".
    const n = transformDictionaryWord(&buf, "world", 9);
    try std.testing.expectEqualStrings("World", buf[0..n]);
}

test "uppercase all" {
    var buf: [512]u8 = undefined;
    // Index 44: "", UPPERCASE_ALL, "".
    const n = transformDictionaryWord(&buf, "world", 44);
    try std.testing.expectEqualStrings("WORLD", buf[0..n]);
}

test "omit last" {
    var buf: [512]u8 = undefined;
    // Index 12: "", OMIT_LAST_1, "".
    const n = transformDictionaryWord(&buf, "words", 12);
    try std.testing.expectEqualStrings("word", buf[0..n]);
}

test "cut off transforms resolve" {
    try std.testing.expectEqual(@as(i16, 0), cut_off_transforms[0]);
    for (cut_off_transforms) |t| {
        try std.testing.expect(t >= -1 and t < num_transforms);
    }
}
