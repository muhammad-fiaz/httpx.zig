//! Library identity — version string and server token.
//!
//! Provides the canonical library name and version, used in `Server`
//! response headers (RFC 9110 Section 12.5.3) and user-agent string
//! construction (RFC 9110 Section 10.1.5).
//!
//! References:
//!   - RFC 9110 Section 10.1.5 — User-Agent
//!   - RFC 9110 Section 12.5.3 — Server Header Field

const std = @import("std");

pub const name = "httpx";
pub const version = "0.2.0";
pub const user_agent = "httpx/0.2.0";
pub const server_token = "httpx/0.2.0";

/// Server header value, e.g. "httpx/0.2.0".
pub fn serverToken(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ name, version }) catch "";
}

/// Default client User-Agent header value, e.g. "httpx/0.2.0".
pub fn userAgent(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ name, version }) catch "";
}

test "server token format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("httpx/0.2.0", serverToken(&buf));
    try std.testing.expectEqualStrings("httpx/0.2.0", userAgent(&buf));
}
