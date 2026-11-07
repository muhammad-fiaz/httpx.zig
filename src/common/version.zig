//! Library identity - version string and server token.
//!
//! Provides the canonical library name and version, used in `Server`
//! response headers (RFC 9110 Section 12.5.3) and user-agent string
//! construction (RFC 9110 Section 10.1.5).
//!
//! References:
//!   - RFC 9110 Section 10.1.5 - User-Agent
//!   - RFC 9110 Section 12.5.3 - Server Header Field

const std = @import("std");

pub const name = "httpx";
pub const version = "0.2.4";
/// Default `User-Agent` value sent by the built-in client.
pub const userAgent = name ++ "/" ++ version;

/// Default metadata for generated API documentation and the `Server` header.
pub const Info = struct {
    title: []const u8 = "HTTPX API",
    version: []const u8 = version,
    description: []const u8 = "Fast, modern web framework for Zig with automated OpenAPI & GraphQL documentation.",
};

pub const defaultInfo: Info = .{};

test "version identity" {
    try std.testing.expectEqualStrings("httpx/0.2.4", userAgent);
}
