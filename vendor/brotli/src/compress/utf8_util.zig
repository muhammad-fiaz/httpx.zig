//! UTF-8 heuristics and utilities for encoder context mode selection.
//!
//! Evaluates whether an input buffer has a sufficient proportion of valid UTF-8
//! encoded data to benefit from UTF-8 context modeling.

const std = @import("std");

pub const MIN_UTF8_RATIO: f64 = 0.75;

/// Parses one UTF-8 sequence from `input`.
/// Returns the number of bytes consumed (1..4) and whether it was a valid UTF-8 sequence.
pub fn parseUtf8(input: []const u8) struct { bytes: usize, valid: bool } {
    if (input.len == 0) return .{ .bytes = 0, .valid = false };
    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return .{ .bytes = 1, .valid = false };
    if (input.len >= len) {
        if (std.unicode.utf8Decode(input[0..len])) |_| {
            return .{ .bytes = len, .valid = true };
        } else |_| {}
    }
    return .{ .bytes = 1, .valid = false };
}

/// Checks whether at least `min_fraction` of `data` consists of valid UTF-8 sequences.
pub fn isMostlyUTF8(data: []const u8, min_fraction: f64) bool {
    if (data.len == 0) return true;

    // Fast-path: use standard library validation for completely valid UTF-8 slices
    if (std.unicode.utf8ValidateSlice(data)) return true;

    var size_utf8: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const res = parseUtf8(data[i..]);
        if (res.valid) {
            size_utf8 += res.bytes;
        }
        i += res.bytes;
    }

    return @as(f64, @floatFromInt(size_utf8)) > min_fraction * @as(f64, @floatFromInt(data.len));
}

pub fn brotliParseAsUTF8(symbol: *i32, input: []const u8) usize {
    if (input.len == 0) {
        symbol.* = 0x110000;
        return 0;
    }
    if ((input[0] & 0x80) == 0) {
        symbol.* = input[0];
        if (symbol.* > 0) return 1;
    }
    if (std.unicode.utf8ByteSequenceLength(input[0])) |len| {
        if (len > 1 and input.len >= len) {
            if (std.unicode.utf8Decode(input[0..len])) |cp| {
                symbol.* = @intCast(cp);
                return len;
            } else |_| {}
        }
    } else |_| {}
    symbol.* = 0x110000 | @as(i32, input[0]);
    return 1;
}

pub fn brotliIsMostlyUTF8(
    data: []const u8,
    pos: usize,
    mask: usize,
    length: usize,
    min_fraction: f64,
) bool {
    if (length == 0) return true;
    const start_pos = pos & mask;
    if (start_pos + length <= data.len) {
        if (std.unicode.utf8ValidateSlice(data[start_pos .. start_pos + length])) return true;
    }
    var size_utf8: usize = 0;
    var i: usize = 0;
    while (i < length) {
        var symbol: i32 = 0;
        const sub_len = length - i;
        const cur_pos = (pos + i) & mask;
        const slice = data[cur_pos..@min(cur_pos + sub_len, data.len)];
        const bytes_read = brotliParseAsUTF8(&symbol, slice);
        i += bytes_read;
        if (symbol < 0x110000) size_utf8 += bytes_read;
    }
    return @as(f64, @floatFromInt(size_utf8)) > min_fraction * @as(f64, @floatFromInt(length));
}

test "utf8 heuristics identify text and binary" {
    const text = "Hello, world! This is a test of UTF-8 text with symbols: café, résumé, 🦀.";
    try std.testing.expect(isMostlyUTF8(text, MIN_UTF8_RATIO));

    // Arbitrary binary
    const binary = [_]u8{ 0xFF, 0xFE, 0x80, 0x81, 0x82, 0xC0, 0x00, 0xF5, 0xC1, 0xFF };
    try std.testing.expect(!isMostlyUTF8(&binary, MIN_UTF8_RATIO));

    // Mixed predominantly text
    var mixed: [100]u8 = undefined;
    @memset(mixed[0..80], 'A');
    @memset(mixed[80..100], 0xFF);
    try std.testing.expect(isMostlyUTF8(&mixed, MIN_UTF8_RATIO));
}
