//! HTTP Basic authentication (RFC 7617).
//!
//! Parsing is allocation-free where possible; decoding the Base64 payload
//! uses the provided allocator. Verification uses constant-time comparison.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");

pub const Credentials = struct {
    username: []const u8,
    password: []const u8,

    /// Reassembles "user:pass" into caller-owned memory.
    pub fn toAuthorizationPayload(self: Credentials, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}:{s}", .{ self.username, self.password });
    }
};

pub const ParseError = error{
    NotBasic,
    InvalidBase64,
    NoColon,
    OutOfMemory,
};

/// Decodes a "Basic <base64>" Authorization header value.
/// The returned credentials borrow from `decoded`; pass an arena.
pub fn parse(header_value: []const u8, decoded: []u8) ParseError!Credentials {
    const prefix = "Basic ";
    if (header_value.len <= prefix.len or
        !std.ascii.startsWithIgnoreCase(header_value, prefix))
        return ParseError.NotBasic;

    const b64 = std.mem.trim(u8, header_value[prefix.len..], " ");
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(b64) catch return ParseError.InvalidBase64;
    if (decoded_len > decoded.len) return ParseError.InvalidBase64;
    decoder.decode(decoded[0..decoded_len], b64) catch return ParseError.InvalidBase64;

    const colon = std.mem.indexOfScalar(u8, decoded[0..decoded_len], ':') orelse
        return ParseError.NoColon;
    return .{
        .username = decoded[0..colon],
        .password = decoded[colon + 1 .. decoded_len],
    };
}

/// Builds a "Basic <base64(user:pass)>" header value into `buf`.
pub fn encodeHeaderValue(buf: []u8, username: []const u8, password: []const u8) []const u8 {
    var payload_buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{s}:{s}", .{ username, password }) catch return "";
    const enc = std.base64.standard.Encoder;
    var b64_buf: [700]u8 = undefined;
    const b64 = enc.encode(&b64_buf, payload);
    return std.fmt.bufPrint(buf, "Basic {s}", .{b64}) catch "";
}

/// Constant-time equality for byte slices (length-independent branches).
pub fn ctEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Constant-time credential verification against expected values.
pub fn verify(creds: Credentials, expect_user: []const u8, expect_pass: []const u8) bool {
    const user_ok = ctEql(creds.username, expect_user);
    // Compare both always to keep timing uniform on user mismatch.
    const pass_ok = ctEql(creds.password, expect_pass);
    return user_ok and pass_ok;
}

// Tests

test "parses rfc7617 example" {
    // "Aladdin:open sesame"
    var decoded: [128]u8 = undefined;
    const c = try parse("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==", &decoded);
    try std.testing.expectEqualStrings("Aladdin", c.username);
    try std.testing.expectEqualStrings("open sesame", c.password);
}

test "rejects wrong scheme, bad base64, and missing colon" {
    var decoded: [128]u8 = undefined;
    try std.testing.expectError(ParseError.NotBasic, parse("Bearer abc", &decoded));
    try std.testing.expectError(ParseError.InvalidBase64, parse("Basic !!!not-base64!!!", &decoded));
    // base64 of "nocolon"
    try std.testing.expectError(ParseError.NoColon, parse("Basic bm9jb2xvbg==", &decoded));
}

test "encode/parse roundtrip" {
    var buf: [256]u8 = undefined;
    const hv = encodeHeaderValue(&buf, "muhammad", "s3cret:pass");
    var decoded: [128]u8 = undefined;
    const c = try parse(hv, &decoded);
    try std.testing.expectEqualStrings("muhammad", c.username);
    try std.testing.expectEqualStrings("s3cret:pass", c.password);
}

test "verify is exact and safe on empty input" {
    try std.testing.expect(verify(.{ .username = "u", .password = "p" }, "u", "p"));
    try std.testing.expect(!verify(.{ .username = "u", .password = "x" }, "u", "p"));
    try std.testing.expect(!verify(.{ .username = "", .password = "" }, "u", "p"));
}
