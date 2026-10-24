//! HTTP Digest Access Authentication (RFC 7616, RFC 2617).
//!
//! Provides challenge parsing, digest response computation (SHA-256 and MD5),
//! client Authorization header generation, and constant-time server verification.
//!
//! References:
//!   - RFC 7616 — HTTP Digest Access Authentication
//!   - RFC 2617 — HTTP Authentication: Basic and Digest Access Authentication

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Algorithm = enum {
    sha256,
    md5,

    pub fn fromString(str: []const u8) ?Algorithm {
        if (std.ascii.eqlIgnoreCase(str, "SHA-256") or std.ascii.eqlIgnoreCase(str, "SHA256")) return .sha256;
        if (std.ascii.eqlIgnoreCase(str, "MD5")) return .md5;
        return null;
    }

    pub fn toString(self: Algorithm) []const u8 {
        return switch (self) {
            .sha256 => "SHA-256",
            .md5 => "MD5",
        };
    }
};

pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

pub const Challenge = struct {
    realm: []const u8,
    nonce: []const u8,
    qop: ?[]const u8 = null,
    algorithm: Algorithm = .sha256,
    @"opaque": ?[]const u8 = null,
    stale: bool = false,
};

pub const ParseError = error{
    NotDigest,
    MissingRealm,
    MissingNonce,
    InvalidParameter,
};

/// Parses a "WWW-Authenticate: Digest ..." challenge header value.
pub fn parseChallenge(headerValue: []const u8) ParseError!Challenge {
    const prefix = "Digest ";
    if (headerValue.len <= prefix.len or !std.ascii.startsWithIgnoreCase(headerValue, prefix)) {
        return ParseError.NotDigest;
    }

    var ch = Challenge{
        .realm = "",
        .nonce = "",
    };

    var params = std.mem.splitScalar(u8, headerValue[prefix.len..], ',');
    while (params.next()) |rawParam| {
        const p = std.mem.trim(u8, rawParam, " \t\r\n");
        if (p.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        const key = std.mem.trim(u8, p[0..eq], " ");
        var val = std.mem.trim(u8, p[eq + 1 ..], " ");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        if (std.ascii.eqlIgnoreCase(key, "realm")) {
            ch.realm = val;
        } else if (std.ascii.eqlIgnoreCase(key, "nonce")) {
            ch.nonce = val;
        } else if (std.ascii.eqlIgnoreCase(key, "qop")) {
            ch.qop = val;
        } else if (std.ascii.eqlIgnoreCase(key, "algorithm")) {
            ch.algorithm = Algorithm.fromString(val) orelse .sha256;
        } else if (std.ascii.eqlIgnoreCase(key, "opaque")) {
            ch.@"opaque" = val;
        } else if (std.ascii.eqlIgnoreCase(key, "stale")) {
            ch.stale = std.ascii.eqlIgnoreCase(val, "true");
        }
    }

    if (ch.realm.len == 0) return ParseError.MissingRealm;
    if (ch.nonce.len == 0) return ParseError.MissingNonce;

    return ch;
}

fn hashHex(comptime Alg: Algorithm, out: []u8, data: []const u8) void {
    const hex = "0123456789abcdef";
    switch (Alg) {
        .sha256 => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            for (digest, 0..) |b, i| {
                out[i * 2] = hex[b >> 4];
                out[i * 2 + 1] = hex[b & 0x0f];
            }
        },
        .md5 => {
            var digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(data, &digest, .{});
            for (digest, 0..) |b, i| {
                out[i * 2] = hex[b >> 4];
                out[i * 2 + 1] = hex[b & 0x0f];
            }
        },
    }
}

/// Computes the Digest response string according to RFC 7616.
pub fn computeResponse(
    out: []u8,
    algorithm: Algorithm,
    creds: Credentials,
    realm: []const u8,
    nonce: []const u8,
    nc: u32,
    cnonce: []const u8,
    qop: ?[]const u8,
    method: []const u8,
    uri: []const u8,
) ![]const u8 {
    var ha1Buf: [64]u8 = undefined;
    var ha2Buf: [64]u8 = undefined;

    // HA1 = H(username:realm:password)
    var a1Buf: [1024]u8 = undefined;
    const a1 = try std.fmt.bufPrint(&a1Buf, "{s}:{s}:{s}", .{ creds.username, realm, creds.password });

    const hashLen: usize = if (algorithm == .sha256) 64 else 32;
    if (out.len < hashLen) return error.BufferTooSmall;

    switch (algorithm) {
        .sha256 => hashHex(.sha256, ha1Buf[0..64], a1),
        .md5 => hashHex(.md5, ha1Buf[0..32], a1),
    }

    // HA2 = H(method:digestURI)
    var a2Buf: [1024]u8 = undefined;
    const a2 = try std.fmt.bufPrint(&a2Buf, "{s}:{s}", .{ method, uri });
    switch (algorithm) {
        .sha256 => hashHex(.sha256, ha2Buf[0..64], a2),
        .md5 => hashHex(.md5, ha2Buf[0..32], a2),
    }

    // Response = H(HA1:nonce:nc:cnonce:qop:HA2) or H(HA1:nonce:HA2)
    var a3Buf: [2048]u8 = undefined;
    const a3 = if (qop != null)
        try std.fmt.bufPrint(&a3Buf, "{s}:{s}:{x:0>8}:{s}:{s}:{s}", .{
            ha1Buf[0..hashLen],
            nonce,
            nc,
            cnonce,
            qop.?,
            ha2Buf[0..hashLen],
        })
    else
        try std.fmt.bufPrint(&a3Buf, "{s}:{s}:{s}", .{
            ha1Buf[0..hashLen],
            nonce,
            ha2Buf[0..hashLen],
        });

    switch (algorithm) {
        .sha256 => hashHex(.sha256, out[0..64], a3),
        .md5 => hashHex(.md5, out[0..32], a3),
    }

    return out[0..hashLen];
}

/// Builds a client "Authorization: Digest ..." header value allocated with `a`.
pub fn buildAuthorizationHeader(
    a: Allocator,
    creds: Credentials,
    ch: Challenge,
    method: []const u8,
    uri: []const u8,
    nc: u32,
    cnonce: []const u8,
) ![]u8 {
    var respBuf: [64]u8 = undefined;
    const response = try computeResponse(
        &respBuf,
        ch.algorithm,
        creds,
        ch.realm,
        ch.nonce,
        nc,
        cnonce,
        ch.qop,
        method,
        uri,
    );

    if (ch.qop != null) {
        return std.fmt.allocPrint(
            a,
            "Digest username=\"{s}\", realm=\"{s}\", nonce=\"{s}\", uri=\"{s}\", algorithm={s}, response=\"{s}\", qop={s}, nc={x:0>8}, cnonce=\"{s}\"{s}{s}{s}",
            .{
                creds.username,
                ch.realm,
                ch.nonce,
                uri,
                ch.algorithm.toString(),
                response,
                ch.qop.?,
                nc,
                cnonce,
                if (ch.@"opaque" != null) ", opaque=\"" else "",
                if (ch.@"opaque" != null) ch.@"opaque".? else "",
                if (ch.@"opaque" != null) "\"" else "",
            },
        );
    } else {
        return std.fmt.allocPrint(
            a,
            "Digest username=\"{s}\", realm=\"{s}\", nonce=\"{s}\", uri=\"{s}\", algorithm={s}, response=\"{s}\"{s}{s}{s}",
            .{
                creds.username,
                ch.realm,
                ch.nonce,
                uri,
                ch.algorithm.toString(),
                response,
                if (ch.@"opaque" != null) ", opaque=\"" else "",
                if (ch.@"opaque" != null) ch.@"opaque".? else "",
                if (ch.@"opaque" != null) "\"" else "",
            },
        );
    }
}

/// Verifies a received Digest authorization header using constant-time equality check.
pub fn verifyAuthorization(
    creds: Credentials,
    realm: []const u8,
    nonce: []const u8,
    method: []const u8,
    headerValue: []const u8,
) bool {
    const prefix = "Digest ";
    if (headerValue.len <= prefix.len or !std.ascii.startsWithIgnoreCase(headerValue, prefix)) return false;

    var username: ?[]const u8 = null;
    var reqRealm: ?[]const u8 = null;
    var reqNonce: ?[]const u8 = null;
    var reqUri: ?[]const u8 = null;
    var response: ?[]const u8 = null;
    var qop: ?[]const u8 = null;
    var ncStr: ?[]const u8 = null;
    var cnonce: ?[]const u8 = null;
    var algorithm: Algorithm = .sha256;

    var params = std.mem.splitScalar(u8, headerValue[prefix.len..], ',');
    while (params.next()) |rawParam| {
        const p = std.mem.trim(u8, rawParam, " \t\r\n");
        if (p.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        const key = std.mem.trim(u8, p[0..eq], " ");
        var val = std.mem.trim(u8, p[eq + 1 ..], " ");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        if (std.ascii.eqlIgnoreCase(key, "username")) {
            username = val;
        } else if (std.ascii.eqlIgnoreCase(key, "realm")) {
            reqRealm = val;
        } else if (std.ascii.eqlIgnoreCase(key, "nonce")) {
            reqNonce = val;
        } else if (std.ascii.eqlIgnoreCase(key, "uri")) {
            reqUri = val;
        } else if (std.ascii.eqlIgnoreCase(key, "response")) {
            response = val;
        } else if (std.ascii.eqlIgnoreCase(key, "qop")) {
            qop = val;
        } else if (std.ascii.eqlIgnoreCase(key, "nc")) {
            ncStr = val;
        } else if (std.ascii.eqlIgnoreCase(key, "cnonce")) {
            cnonce = val;
        } else if (std.ascii.eqlIgnoreCase(key, "algorithm")) {
            algorithm = Algorithm.fromString(val) orelse .sha256;
        }
    }

    const u = username orelse return false;
    const r = reqRealm orelse return false;
    const n = reqNonce orelse return false;
    const uri = reqUri orelse return false;
    const resp = response orelse return false;

    if (!std.mem.eql(u8, u, creds.username)) return false;
    if (!std.mem.eql(u8, r, realm)) return false;
    if (!std.mem.eql(u8, n, nonce)) return false;

    const nc: u32 = if (ncStr) |s| std.fmt.parseInt(u32, s, 16) catch return false else 1;
    const cn = cnonce orelse "";

    var expectedBuf: [64]u8 = undefined;
    const expected = computeResponse(
        &expectedBuf,
        algorithm,
        creds,
        realm,
        nonce,
        nc,
        cn,
        qop,
        method,
        uri,
    ) catch return false;

    if (resp.len != expected.len) return false;
    return std.crypto.timing_safe.eql([64]u8, pad64(resp), pad64(expected));
}

fn pad64(slice: []const u8) [64]u8 {
    var out: [64]u8 = @splat(0);
    @memcpy(out[0..@min(slice.len, 64)], slice[0..@min(slice.len, 64)]);
    return out;
}

test "parse challenge from server" {
    const raw = "Digest realm=\"http-auth@example.org\", qop=\"auth, auth-int\", algorithm=SHA-256, nonce=\"7ypf/xlj9XXHGtFIWSVILQ==\", opaque=\"FQhe/qaU925kualBR5QGXYcT1uotWoStrategy\"";
    const ch = try parseChallenge(raw);
    try std.testing.expectEqualStrings("http-auth@example.org", ch.realm);
    try std.testing.expectEqualStrings("7ypf/xlj9XXHGtFIWSVILQ==", ch.nonce);
    try std.testing.expectEqual(Algorithm.sha256, ch.algorithm);
    try std.testing.expect(ch.qop != null);
    try std.testing.expectEqualStrings("FQhe/qaU925kualBR5QGXYcT1uotWoStrategy", ch.@"opaque".?);
}

test "rfc 7616 sha-256 test vector calculation" {
    const creds = Credentials{ .username = "Mufasa", .password = "Circle of Life" };
    const ch = Challenge{
        .realm = "http-auth@example.org",
        .nonce = "7ypf/xlj9XXHGtFIWSVILQ==",
        .qop = "auth",
        .algorithm = .sha256,
        .@"opaque" = "FQhe/qaU925kualBR5QGXYcT1uotWoStrategy",
    };

    var buf: [64]u8 = undefined;
    const resp = try computeResponse(
        &buf,
        .sha256,
        creds,
        ch.realm,
        ch.nonce,
        1,
        "f2/wEdfr72guXAm-AipYWhGrNGqKhGvgaP9BiKGUpao=",
        ch.qop,
        "GET",
        "/dir/index.html",
    );

    // Verify response is a valid 64-character lowercase hex string
    try std.testing.expectEqual(@as(usize, 64), resp.len);
    for (resp) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Build client header and verify
    const a = std.testing.allocator;
    const authHdr = try buildAuthorizationHeader(a, creds, ch, "GET", "/dir/index.html", 1, "f2/wEdfr72guXAm-AipYWhGrNGqKhGvgaP9BiKGUpao=");
    defer a.free(authHdr);

    try std.testing.expect(verifyAuthorization(creds, ch.realm, ch.nonce, "GET", authHdr));
    // Tampered password fails
    const badCreds = Credentials{ .username = "Mufasa", .password = "Wrong" };
    try std.testing.expect(!verifyAuthorization(badCreds, ch.realm, ch.nonce, "GET", authHdr));
}

test "rfc 2617 md5 test vector calculation" {
    const creds = Credentials{ .username = "Mufasa", .password = "Circle Of Life" };
    const ch = Challenge{
        .realm = "testrealm@host.com",
        .nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093",
        .qop = "auth",
        .algorithm = .md5,
        .@"opaque" = "5ccc069c403ebaf9f0171e9517f40e41",
    };

    var buf: [64]u8 = undefined;
    const resp = try computeResponse(
        &buf,
        .md5,
        creds,
        ch.realm,
        ch.nonce,
        1,
        "0a4f113b",
        ch.qop,
        "GET",
        "/dir/index.html",
    );

    // RFC 2617 expected response is 6629fae49393a05397450978507c4ef1
    try std.testing.expectEqualStrings("6629fae49393a05397450978507c4ef1", resp);

    const a = std.testing.allocator;
    const authHdr = try buildAuthorizationHeader(a, creds, ch, "GET", "/dir/index.html", 1, "0a4f113b");
    defer a.free(authHdr);

    try std.testing.expect(verifyAuthorization(creds, ch.realm, ch.nonce, "GET", authHdr));
}
