//! Library identity — version string and server token.
//!
//! Provides the canonical library name and version, used in `Server`
//! response headers (RFC 9110 Section 12.5.3) and user-agent string
//! construction (RFC 9110 Section 10.1.5).
//!
//! References:
//!   - RFC 9110 Section 10.1.5 — User-Agent
//!   - RFC 9110 Section 12.5.3 — Server Header Field

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
