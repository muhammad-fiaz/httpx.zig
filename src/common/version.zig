//! Library identity, shared by docs, server headers, and the root module.

pub const name = "HTTPX";
pub const version = "0.2.0";

/// Server header value, e.g. "HTTPX/0.2.0".
pub fn serverToken(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ name, version }) catch "";
}

const std = @import("std");

test "server token format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("HTTPX/0.2.0", serverToken(&buf));
}
