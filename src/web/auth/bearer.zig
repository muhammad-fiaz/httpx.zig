//! Bearer token (RFC 6750) and API-key Authorization helpers.

const std = @import("std");
const router_mod = @import("../router/router.zig");

pub const Scheme = enum { bearer, api_key };

pub const Extracted = struct {
    scheme: Scheme,
    /// Token borrowed from the header value.
    token: []const u8,
};

/// Extracts "Bearer <token>".
pub fn parseBearer(header_value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (!std.ascii.startsWithIgnoreCase(header_value, prefix)) return null;
    const token = std.mem.trim(u8, header_value[prefix.len..], " ");
    if (token.len == 0) return null;
    return token;
}

/// Extracts a custom-scheme API key, e.g. "X-Key abc123" or any scheme name.
pub fn parseApiKey(header_value: []const u8, scheme: []const u8) ?[]const u8 {
    if (scheme.len == 0) return null;
    if (!std.ascii.startsWithIgnoreCase(header_value, scheme)) return null;
    var rest = header_value[scheme.len..];
    if (rest.len == 0 or rest[0] != ' ') return null; // require separator
    rest = std.mem.trim(u8, rest, " ");
    if (rest.len == 0) return null;
    return rest;
}

/// Constant-time token comparison.
pub fn verifyToken(actual: []const u8, expected: []const u8) bool {
    return @import("basic.zig").ctEql(actual, expected);
}

/// Convenience: authorize a request context against one expected Bearer token.
pub fn authorizeBearer(ctx: *const router_mod.Context, header_name: []const u8, expected: []const u8) bool {
    const hv = ctx.header(header_name) orelse return false;
    const tok = parseBearer(hv) orelse return false;
    return verifyToken(tok, expected);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bearer extraction is case-insensitive and trims" {
    try std.testing.expectEqualStrings("tok", parseBearer("Bearer tok").?);
    try std.testing.expectEqualStrings("tok", parseBearer("BEARER   tok ").?);
    try std.testing.expect(parseBearer("Basic x") == null);
    try std.testing.expect(parseBearer("Bearer ") == null);
    try std.testing.expect(parseBearer("") == null);
}

test "api key uses exact scheme with separator" {
    try std.testing.expectEqualStrings("k1", parseApiKey("X-Key k1", "X-Key").?);
    try std.testing.expectEqualStrings("k1", parseApiKey("x-key  k1 ", "X-Key").?);
    try std.testing.expect(parseApiKey("X-Keyk1", "X-Key") == null); // no space
    try std.testing.expect(parseApiKey("Other k1", "X-Key") == null);
}

test "token verification rejects wrong lengths safely" {
    try std.testing.expect(verifyToken("abc", "abc"));
    try std.testing.expect(!verifyToken("abc", "abd"));
    try std.testing.expect(!verifyToken("abc", "abcd"));
}
