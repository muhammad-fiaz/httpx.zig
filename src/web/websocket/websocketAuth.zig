//! WebSocket handshake authentication shared by client and server.
//!
//! Reuses the existing HTTP auth modules (`basicAuth`, `bearerAuth`) instead of
//! re-implementing credential parsing. Client configuration produces the
//! `Authorization` line for the opening handshake; server configuration
//! validates it before the upgrade with constant-time comparisons.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zigantic");
const basic = @import("../auth/basicAuth.zig");
const bearer = @import("../auth/bearerAuth.zig");

pub const Scheme = enum { none, basic, bearer };

pub const ConfigSchema = z.objectOf(.{
    .scheme = z.withDefault(z.enumType(Scheme, .{}), .none),
    .username = z.withDefault(z.string(.{}), ""),
    .password = z.withDefault(z.string(.{}), ""),
    .token = z.withDefault(z.string(.{}), ""),
    .realm = z.withDefault(z.string(.{}), "WebSocket"),
}, .{});
pub const Config = ConfigSchema.Value;

/// Builds the `Authorization` header value for a client handshake, or null
/// when authentication is disabled. Caller owns the returned buffer.
pub fn clientHeaderValue(allocator: Allocator, cfg: Config) !?[]u8 {
    return switch (cfg.scheme) {
        .none => null,
        .basic => blk: {
            const payloadLen = std.base64.standard.Encoder.calcSize(cfg.username.len + 1 + cfg.password.len);
            const value = try allocator.alloc(u8, "Basic ".len + payloadLen);
            _ = basic.encodeHeaderValue(value, cfg.username, cfg.password);
            break :blk value;
        },
        .bearer => try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.token}),
    };
}

/// True when the request satisfies the configured server authentication.
/// `headerValue` is the raw `Authorization` header (empty when absent).
pub fn verify(cfg: Config, headerValue: []const u8) bool {
    return switch (cfg.scheme) {
        .none => true,
        .basic => blk: {
            var decoded: [1024]u8 = undefined;
            const creds = basic.parse(headerValue, &decoded) catch break :blk false;
            break :blk basic.verify(creds, cfg.username, cfg.password);
        },
        .bearer => blk: {
            const presented = bearer.parseBearer(headerValue) orelse break :blk false;
            break :blk bearer.verifyToken(presented, cfg.token);
        },
    };
}

/// Value for the `WWW-Authenticate` response header on a 401.
pub fn challenge(cfg: Config) []const u8 {
    return switch (cfg.scheme) {
        .basic => "Basic",
        .bearer => "Bearer",
        .none => "Basic",
    };
}

test "basic client header verifies on the server" {
    const cfg = Config{ .scheme = .basic, .username = "u", .password = "p" };
    const value = (try clientHeaderValue(std.testing.allocator, cfg)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expect(verify(cfg, value));
    try std.testing.expect(!verify(cfg, "Basic bm9wZQ=="));
}

test "bearer client header verifies on the server" {
    const cfg = Config{ .scheme = .bearer, .token = "secret" };
    const value = (try clientHeaderValue(std.testing.allocator, cfg)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Bearer secret", value);
    try std.testing.expect(verify(cfg, value));
    try std.testing.expect(!verify(cfg, "Bearer other"));
}

test "disabled auth accepts any header" {
    try std.testing.expect(verify(.{}, ""));
    try std.testing.expect(verify(.{}, "Basic anything"));
}
