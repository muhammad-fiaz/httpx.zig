//! Owned response-body fixture helpers used by testing-server tests.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Returns an owned body of `len` bytes filled with `byte`.
pub fn repeated(allocator: Allocator, byte: u8, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    @memset(out, byte);
    return out;
}

/// Serializes `value` to an owned JSON byte slice.
pub fn jsonBody(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "body fixtures are owned and independent" {
    const allocator = std.testing.allocator;
    const body = try repeated(allocator, 'x', 8);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("xxxxxxxx", body);

    const json = try jsonBody(allocator, .{ .ok = true });
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"ok\":true}", json);
}
