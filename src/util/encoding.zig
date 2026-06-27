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
    /// Encodes data to standard Base64.
    pub fn encode(allocator: Allocator, data: []const u8) ![]u8 {
        const len = std.base64.standard.Encoder.calcSize(data.len);
        const result = try allocator.alloc(u8, len);
        _ = std.base64.standard.Encoder.encode(result, data);
        return result;
    }

    /// Decodes Base64 data.
    pub fn decode(allocator: Allocator, data: []const u8) ![]u8 {
        const len = try std.base64.standard.Decoder.calcSizeForSlice(data);
        const result = try allocator.alloc(u8, len);
        try std.base64.standard.Decoder.decode(result, data);
        return result;
    }

    /// Encodes to URL-safe Base64 (no padding).
    pub fn encodeUrl(allocator: Allocator, data: []const u8) ![]u8 {
        const len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
        const result = try allocator.alloc(u8, len);
        _ = std.base64.url_safe_no_pad.Encoder.encode(result, data);
        return result;
    }

    /// Formats a Basic authentication header value.
    /// The caller owns the returned slice.
    pub fn formatBasicAuth(allocator: Allocator, username: []const u8, password: []const u8) ![]u8 {
        const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
        defer allocator.free(credentials);

        const encoded = try Base64.encode(allocator, credentials);
        defer allocator.free(encoded);

        return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    }
};

/// Hexadecimal encoding and decoding.
pub const Hex = struct {
    /// Encodes data to lowercase hexadecimal.
    pub fn encode(allocator: Allocator, data: []const u8) ![]u8 {
        var result = try allocator.alloc(u8, data.len * 2);
        const hex_chars = "0123456789abcdef";
        for (data, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return result;
    }

    /// Decodes hexadecimal data.
    pub fn decode(allocator: Allocator, data: []const u8) ![]u8 {
        if (data.len % 2 != 0) return error.InvalidHex;
        const result = try allocator.alloc(u8, data.len / 2);
        _ = std.fmt.hexToBytes(result, data) catch return error.InvalidHex;
        return result;
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
