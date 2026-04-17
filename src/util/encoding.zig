//! Encoding Utilities for httpx.zig
//!
//! Provides encoding and decoding utilities commonly used in HTTP:
//!
//! - Base64 encoding/decoding for Authorization headers
//! - Hexadecimal encoding for checksums and tokens
//! - URL percent-encoding for query strings and path segments
//! - Form data encoding (application/x-www-form-urlencoded)

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_writer = @import("list_writer.zig");

/// Base64 encoding and decoding per RFC 4648.
pub const Base64 = struct {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    /// Encodes data to standard Base64.
    pub fn encode(allocator: Allocator, data: []const u8) ![]u8 {
        const len = ((data.len + 2) / 3) * 4;
        var result = try allocator.alloc(u8, len);
        var i: usize = 0;
        var j: usize = 0;

        while (i < data.len) {
            const b0 = data[i];
            const b1 = if (i + 1 < data.len) data[i + 1] else 0;
            const b2 = if (i + 2 < data.len) data[i + 2] else 0;

            result[j] = alphabet[b0 >> 2];
            result[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j + 2] = if (i + 1 < data.len) alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)] else '=';
            result[j + 3] = if (i + 2 < data.len) alphabet[b2 & 0x3F] else '=';

            i += 3;
            j += 4;
        }

        return result;
    }

    /// Decodes Base64 data.
    pub fn decode(allocator: Allocator, data: []const u8) ![]u8 {
        if (data.len == 0) return allocator.alloc(u8, 0);
        if (data.len % 4 != 0) return error.InvalidBase64;

        var padding: usize = 0;
        if (data[data.len - 1] == '=') padding += 1;
        if (data[data.len - 2] == '=') padding += 1;

        const out_len = (data.len / 4) * 3 - padding;
        var result = try allocator.alloc(u8, out_len);
        var i: usize = 0;
        var j: usize = 0;

        while (i < data.len) {
            const c0 = indexOf(alphabet, data[i]) orelse return error.InvalidBase64;
            const c1 = indexOf(alphabet, data[i + 1]) orelse return error.InvalidBase64;
            const c2 = if (data[i + 2] == '=') @as(u6, 0) else indexOf(alphabet, data[i + 2]) orelse return error.InvalidBase64;
            const c3 = if (data[i + 3] == '=') @as(u6, 0) else indexOf(alphabet, data[i + 3]) orelse return error.InvalidBase64;

            if (j < out_len) result[j] = (@as(u8, c0) << 2) | (@as(u8, c1) >> 4);
            if (j + 1 < out_len) result[j + 1] = (@as(u8, c1) << 4) | (@as(u8, c2) >> 2);
            if (j + 2 < out_len) result[j + 2] = (@as(u8, c2) << 6) | @as(u8, c3);

            i += 4;
            j += 3;
        }

        return result;
    }

    /// Encodes to URL-safe Base64 (no padding).
    pub fn encodeUrl(allocator: Allocator, data: []const u8) ![]u8 {
        const result = try encode(allocator, data);
        for (result) |*c| {
            if (c.* == '+') c.* = '-';
            if (c.* == '/') c.* = '_';
        }
        var end = result.len;
        while (end > 0 and result[end - 1] == '=') end -= 1;
        return allocator.realloc(result, end);
    }

    fn indexOf(chars: []const u8, c: u8) ?u6 {
        for (chars, 0..) |ch, i| {
            if (ch == c) return @intCast(i);
        }
        return null;
    }
};

/// Hexadecimal encoding and decoding.
pub const Hex = struct {
    const hex_chars = "0123456789abcdef";

    /// Encodes data to lowercase hexadecimal.
    pub fn encode(allocator: Allocator, data: []const u8) ![]u8 {
        var result = try allocator.alloc(u8, data.len * 2);
        for (data, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return result;
    }

    /// Decodes hexadecimal data.
    pub fn decode(allocator: Allocator, data: []const u8) ![]u8 {
        if (data.len % 2 != 0) return error.InvalidHex;

        var result = try allocator.alloc(u8, data.len / 2);
        var i: usize = 0;
        while (i < data.len) {
            const high = hexValue(data[i]) orelse return error.InvalidHex;
            const low = hexValue(data[i + 1]) orelse return error.InvalidHex;
            result[i / 2] = (high << 4) | low;
            i += 2;
        }
        return result;
    }

    fn hexValue(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return null;
    }
};

/// URL percent-encoding per RFC 3986.
pub const PercentEncoding = struct {
    const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

    /// Encodes a string for use in URLs.
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        const writer = list_writer.init(allocator, &result);

        for (input) |c| {
            if (std.mem.indexOfScalar(u8, unreserved, c) != null) {
                try writer.writeByte(c);
            } else {
                try writer.print("%{X:0>2}", .{c});
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Decodes a percent-encoded string.
    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                const hex = input[i + 1 .. i + 3];
                if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                    try result.append(allocator, byte);
                    i += 3;
                    continue;
                } else |_| {}
            }
            if (input[i] == '+') {
                try result.append(allocator, ' ');
            } else {
                try result.append(allocator, input[i]);
            }
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Encodes key-value pairs as application/x-www-form-urlencoded.
pub fn encodeFormData(allocator: Allocator, params: []const struct { []const u8, []const u8 }) ![]u8 {
    var result = std.ArrayList(u8).empty;
    const writer = list_writer.init(allocator, &result);

    for (params, 0..) |param, idx| {
        if (idx > 0) try writer.writeByte('&');
        const key = try PercentEncoding.encode(allocator, param[0]);
        defer allocator.free(key);
        const value = try PercentEncoding.encode(allocator, param[1]);
        defer allocator.free(value);
        try writer.print("{s}={s}", .{ key, value });
    }

    return result.toOwnedSlice(allocator);
}

test "Base64 encode" {
    const allocator = std.testing.allocator;

    const encoded = try Base64.encode(allocator, "Hello");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("SGVsbG8=", encoded);
}

test "Base64 decode" {
    const allocator = std.testing.allocator;

    const decoded = try Base64.decode(allocator, "SGVsbG8=");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "Base64 roundtrip" {
    const allocator = std.testing.allocator;
    const original = "The quick brown fox!";

    const encoded = try Base64.encode(allocator, original);
    defer allocator.free(encoded);
    const decoded = try Base64.decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "Hex encode" {
    const allocator = std.testing.allocator;

    const encoded = try Hex.encode(allocator, "\x00\xff\x10");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("00ff10", encoded);
}

test "Hex decode" {
    const allocator = std.testing.allocator;

    const decoded = try Hex.decode(allocator, "48656c6c6f");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "Percent encoding" {
    const allocator = std.testing.allocator;

    const encoded = try PercentEncoding.encode(allocator, "hello world!");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world%21", encoded);
}

test "Percent decoding" {
    const allocator = std.testing.allocator;

    const decoded = try PercentEncoding.decode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "Form data encoding" {
    const allocator = std.testing.allocator;

    const encoded = try encodeFormData(allocator, &.{
        .{ "name", "John Doe" },
        .{ "email", "john@example.com" },
    });
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "name=John%20Doe") != null);
}
