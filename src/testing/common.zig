//! Shared types and small helpers for the testing server.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const router = @import("../web/router/router.zig");
pub const httpServer = @import("../server/httpServer.zig");
pub const Method = @import("../common/method.zig").Method;

pub const Header = router.Header;
pub const HeaderSchema = @import("../common/headers.zig").HeaderSchema;
pub const Context = router.Context;
pub const Response = router.Response;
pub const Handler = router.HandlerFn;

/// Case-insensitive lookup in a captured/response header slice.
pub fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Copies a header list and every name/value it references. Caller owns the
/// returned slice and its strings and releases them with `freeHeaders`.
pub fn dupeHeaders(allocator: Allocator, headers: []const Header) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(out);
    }
    for (headers, 0..) |h, i| {
        const name = try allocator.dupe(u8, h.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, h.value);
        out[i] = .{ .name = name, .value = value };
        initialized += 1;
    }
    return out;
}

pub fn freeHeaders(allocator: Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

test "header helpers copy and free independent storage" {
    const allocator = std.testing.allocator;
    const source = [_]Header{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-test", .value = "yes" },
    };
    const copied = try dupeHeaders(allocator, &source);
    defer freeHeaders(allocator, copied);
    try std.testing.expectEqualStrings("text/plain", headerValue(copied, "Content-Type").?);
    try std.testing.expectEqualStrings("yes", headerValue(copied, "X-Test").?);
    try std.testing.expect(headerValue(copied, "missing") == null);
}
