//! Strict X.509 Certificate and Hostname Verification per RFC 6125 and RFC 5280.
//!
//! Enforces:
//!   - Strict wildcard matching (leftmost label only, no matching across dots e.g. *.example.com).
//!   - IP address SAN matching without wildcard support.
//!   - Validity period checks (notBefore <= now <= notAfter).
//!   - BasicConstraints CA verification for intermediate certificates.
//!   - Complete chain verification against a TrustStore.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const Certificate = crypto.Certificate;
const certMod = @import("certificate.zig");
const trustStoreMod = @import("trustStore.zig");
const transportMod = @import("transport.zig");
const clock_mod = @import("../../common/clock.zig");
const errorsMod = @import("errors.zig");
pub const TlsError = errorsMod.TlsError;

/// Verifies a presented server chain (DER list) against the configured
/// trust with hostname checks. Shared by the TCP and QUIC native TLS
/// clients so both enforce identical policy:
/// `.none` skips verification (explicit opt-out); `.selfSigned`
/// accepts a single self-signed leaf; `.caBundle` anchors in the custom
/// CA PEM or, without one, the system trust store. The hostname (DNS
/// name or IP literal) is always checked unless skipped.
pub fn verifyServerChain(
    allocator: Allocator,
    io: std.Io,
    mode: transportMod.VerifyMode,
    caPem: ?[]const u8,
    host: []const u8,
    ders: []const []const u8,
) !void {
    if (mode == .none) return;
    if (ders.len == 0) return error.MissingCertificate;
    var store = trustStoreMod.TrustStore.init(allocator, io);
    defer store.deinit();
    switch (mode) {
        .none => unreachable,
        .selfSigned => {
            store.mode = .selfSigned;
        },
        .caBundle => {
            if (caPem) |pem| {
                var search_from: usize = 0;
                var blocks: usize = 0;
                while (std.mem.indexOfPos(u8, pem, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
                    const der = certMod.decodePemBlock(allocator, pem[idx..], "CERTIFICATE") catch return error.CertificateUntrusted;
                    defer allocator.free(der);
                    if (!certMod.checkDerStructure(der)) return error.CertificateUntrusted;
                    blocks += 1;
                    search_from = idx + 26;
                }
                if (blocks == 0) return error.CertificateUntrusted;
                store.addCertPem(pem) catch return error.CertificateUntrusted;
            } else {
                store.loadSystemTrust() catch return error.CertificateUntrusted;
            }
        },
    }
    const chain = certMod.CertificateChain{ .certs = ders, .allocator = allocator };
    const now_sec: i64 = @divFloor(clock_mod.millisNow(), 1000);
    verifyCertificateChain(chain, &store, host, now_sec) catch |e| switch (e) {
        error.CertificateExpired => return error.CertificateExpired,
        error.CertificateHostMismatch, error.HostnameMismatch => return error.CertificateHostMismatch,
        error.CertificateUntrusted => return error.CertificateUntrusted,
        else => return error.TlsHandshakeFailed,
    };
}

/// Validates whether a DNS pattern matches a target hostname per RFC 6125.
pub fn matchDnsPattern(pattern: []const u8, hostname: []const u8) bool {
    if (pattern.len == 0 or hostname.len == 0) return false;

    // Exact case-insensitive match
    if (std.ascii.eqlIgnoreCase(pattern, hostname)) return true;

    // Wildcard matching: only valid if pattern starts with "*."
    if (pattern.len >= 3 and pattern[0] == '*' and pattern[1] == '.') {
        const pattern_suffix = pattern[1..]; // e.g. ".example.com"

        // Hostname must be longer than the suffix
        if (hostname.len <= pattern_suffix.len) return false;

        // Hostname must end with pattern_suffix case-insensitively
        const host_suffix = hostname[hostname.len - pattern_suffix.len ..];
        if (!std.ascii.eqlIgnoreCase(host_suffix, pattern_suffix)) return false;

        // The prefix matched by "*" must be a single label (no dots)
        const host_prefix = hostname[0 .. hostname.len - pattern_suffix.len];
        if (host_prefix.len == 0) return false;
        if (std.mem.indexOfScalar(u8, host_prefix, '.') != null) {
            // Cannot match across dots (e.g. *.example.com does not match a.b.example.com)
            return false;
        }

        return true;
    }

    return false;
}

/// Verifies whether the given target hostname matches the parsed certificate SANs or Common Name.
/// IP literals are matched against iPAddress SAN entries (which
/// `std.crypto.Certificate.Parsed.verifyHostName` does not cover);
/// DNS names go through std's RFC 6125 verification.
pub fn verifyHostname(parsed: Certificate.Parsed, targetHost: []const u8) TlsError!void {
    if (targetHost.len == 0) return TlsError.HostnameMismatch;

    // Split host/port: [v6]:port, host:port (single colon), or bare host.
    var host_only = targetHost;
    if (targetHost[0] == '[') {
        const close = std.mem.indexOfScalar(u8, targetHost, ']') orelse return TlsError.HostnameMismatch;
        host_only = targetHost[1..close];
    } else if (std.mem.count(u8, targetHost, ":") == 1) {
        const colon = std.mem.indexOfScalar(u8, targetHost, ':').?;
        host_only = targetHost[0..colon];
    }
    if (host_only.len == 0) return TlsError.HostnameMismatch;

    // IP literal targets must match an iPAddress SAN (RFC 6125 Section 6.4.4);
    // DNS matching never applies to them.
    if (parseIpLiteral(host_only)) |ip| {
        if (sanHasIp(parsed, ip)) return;
        return TlsError.CertificateHostMismatch;
    }

    // Use std.crypto.Certificate.Parsed hostname verification.
    parsed.verifyHostName(host_only) catch |err| switch (err) {
        error.CertificateHostMismatch => return TlsError.CertificateHostMismatch,
        error.CertificateFieldHasInvalidLength => return TlsError.HostnameMismatch,
    };
}

/// Parsed IP literal: 4 bytes for IPv4, 16 for IPv6, or null.
pub const ParsedIp = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

pub fn parseIpLiteral(text: []const u8) ?ParsedIp {
    if (parseIpv4(text)) |b| return .{ .v4 = b };
    if (parseIpv6(text)) |b| return .{ .v6 = b };
    return null;
}

fn parseIpv4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (parts >= 4 or part.len == 0 or part.len > 3) return null;
        var v: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
            if (v > 255) return null;
        }
        out[parts] = @intCast(v);
        parts += 1;
    }
    if (parts != 4) return null;
    return out;
}

fn parseIpv6(text: []const u8) ?[16]u8 {
    // Split around at most one "::" compression marker.
    var halves: [2][]const u8 = .{ "", "" };
    var n_halves: usize = 1;
    halves[0] = text;
    if (std.mem.indexOf(u8, text, "::")) |dc| {
        if (std.mem.indexOfPos(u8, text, dc + 2, "::") != null) return null;
        halves[0] = text[0..dc];
        halves[1] = text[dc + 2 ..];
        n_halves = 2;
    }
    var head: [8]u16 = undefined;
    var head_len: usize = 0;
    var tail: [8]u16 = undefined;
    var tail_len: usize = 0;
    for (halves[0..n_halves], 0..) |half, hi| {
        if (half.len == 0) continue;
        var it = std.mem.splitScalar(u8, half, ':');
        while (it.next()) |g| {
            if (g.len == 0 or g.len > 4) return null;
            const v = std.fmt.parseInt(u16, g, 16) catch return null;
            if (hi == 0) {
                if (head_len >= 8) return null;
                head[head_len] = v;
                head_len += 1;
            } else {
                if (tail_len >= 8) return null;
                tail[tail_len] = v;
                tail_len += 1;
            }
        }
    }
    if (n_halves == 1) {
        if (head_len != 8) return null;
    } else if (head_len + tail_len >= 8) {
        return null;
    }
    var out: [16]u8 = [_]u8{0} ** 16;
    for (head[0..head_len], 0..) |g, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], g, .big);
    const tail_off = 16 - tail_len * 2;
    for (tail[0..tail_len], 0..) |g, i| std.mem.writeInt(u16, out[tail_off + i * 2 ..][0..2], g, .big);
    return out;
}

/// True when the certificate's SAN extension carries an iPAddress entry
/// equal to `ip` (4-byte IPv4 or 16-byte IPv6).
fn sanHasIp(parsed: Certificate.Parsed, ip: ParsedIp) bool {
    const san = parsed.subjectAltName();
    if (san.len == 0) return false;
    // GeneralNames is a SEQUENCE of [n] context-specific tags (or, rarely,
    // the bare content riding without its header — accept both layouts).
    var pos: usize = 0;
    var end = san.len;
    if (san.len >= 2 and san[0] == 0x30) {
        pos += 1;
        const seq_len = derLen(san, &pos) orelse return false;
        if (pos + seq_len > san.len) return false;
        end = pos + seq_len;
    }
    while (pos + 2 <= end) {
        const tag = san[pos];
        const is_ip = (tag & 0x1F) == 7 and (tag & 0xC0) == 0x80;
        pos += 1;
        const field_len = derLen(san, &pos) orelse return false;
        if (pos + field_len > end) return false;
        if (is_ip) {
            const val = san[pos..][0..field_len];
            switch (ip) {
                .v4 => |b| if (field_len == 4 and std.mem.eql(u8, val, &b)) return true,
                .v6 => |b| if (field_len == 16 and std.mem.eql(u8, val, &b)) return true,
            }
        }
        pos += field_len;
    }
    return false;
}

/// Reads a DER length at `pos` (short or long form), advancing past it.
fn derLen(data: []const u8, pos: *usize) ?usize {
    if (pos.* + 1 > data.len) return null;
    const first = data[pos.*];
    pos.* += 1;
    if (first & 0x80 == 0) return first;
    const n: usize = first & 0x7F;
    if (n == 0 or n > 2 or pos.* + n > data.len) return null;
    var len: usize = 0;
    for (data[pos.*..][0..n]) |b| len = (len << 8) | b;
    pos.* += n;
    return len;
}

/// Verifies a complete certificate chain against a trust store and hostname.
pub fn verifyCertificateChain(
    chain: certMod.CertificateChain,
    trustStore: *trustStoreMod.TrustStore,
    targetHost: ?[]const u8,
    nowSec: i64,
) TlsError!void {
    if (chain.count() == 0) return TlsError.InvalidCertificateChain;

    // 1. Verify leaf certificate
    const leaf = chain.leaf() orelse return TlsError.InvalidCertificate;

    // Check validity period
    if (leaf.isNotYetValid(nowSec)) return TlsError.CertificateNotYetValid;
    if (leaf.isExpired(nowSec)) return TlsError.CertificateExpired;

    // Check hostname
    if (targetHost) |host| {
        try verifyHostname(leaf.parsed, host);
    }

    // If trust store mode is none, skip root anchor verification
    if (trustStore.mode == .none) return;

    // If self-signed mode and single certificate
    if (trustStore.mode == .selfSigned and chain.count() == 1 and leaf.isSelfSigned()) {
        return;
    }

    // Verify chain signatures up to trust anchor
    var current = leaf;
    var i: usize = 1;
    while (i < chain.count()) : (i += 1) {
        const issuerCert = chain.get(i) orelse return TlsError.InvalidCertificateChain;

        // Intermediate certificate must be a CA
        if (!issuerCert.isCa()) {
            return TlsError.InvalidCertificateChain;
        }

        // Verify validity of intermediate
        if (issuerCert.isNotYetValid(nowSec)) return TlsError.CertificateNotYetValid;
        if (issuerCert.isExpired(nowSec)) return TlsError.CertificateExpired;

        // Verify signature
        try current.verifySignature(issuerCert, nowSec);
        current = issuerCert;
    }

    // Verify top certificate against the trust store
    try trustStore.verify(current.parsed, nowSec);
}

test "matchDnsPattern exact and wildcard" {
    // Exact matches
    try std.testing.expect(matchDnsPattern("example.com", "example.com"));
    try std.testing.expect(matchDnsPattern("example.com", "EXAMPLE.COM"));
    try std.testing.expect(!matchDnsPattern("example.com", "other.com"));

    // Valid wildcard
    try std.testing.expect(matchDnsPattern("*.example.com", "api.example.com"));
    try std.testing.expect(matchDnsPattern("*.example.com", "test.example.com"));

    // Invalid wildcard matches (RFC 6125 rules)
    // 1. Cannot match across dots
    try std.testing.expect(!matchDnsPattern("*.example.com", "sub.api.example.com"));
    // 2. Cannot match apex domain
    try std.testing.expect(!matchDnsPattern("*.example.com", "example.com"));
    // 3. Cannot match partial name without dot
    try std.testing.expect(!matchDnsPattern("*.example.com", "notexample.com"));
}

test "IP literal parsing covers v4, v6, and garbage" {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIpLiteral("127.0.0.1").?.v4);
    try std.testing.expect(parseIpLiteral("999.1.1.1") == null);
    try std.testing.expect(parseIpLiteral("1.2.3") == null);
    try std.testing.expect(parseIpLiteral("example.com") == null);
    try std.testing.expect(parseIpLiteral("") == null);
    const v6 = parseIpLiteral("::1").?.v6;
    var want: [16]u8 = [_]u8{0} ** 16;
    want[15] = 1;
    try std.testing.expectEqual(want, v6);
    const full = parseIpLiteral("2001:db8:0:0:0:0:2:1").?.v6;
    try std.testing.expectEqual(@as(u8, 0x20), full[0]);
    try std.testing.expect(parseIpLiteral(":::") == null);
    try std.testing.expect(parseIpLiteral("1::2::3") == null);
}

const localhost_cert_pem = @embedFile("testdata/localhost_cert.pem");

// Test fixture validity: 2026-09-09 .. 2036-09-06. nowSec values below are
// chosen well inside (1800000000 = 2027-01-15), before (1700000000), and
// after (2200000000 = 2039) that window.
test "self-signed fixture verifies hostname and validity window" {
    const a = std.testing.allocator;
    var chain = try certMod.parseCertificateChainPem(a, localhost_cert_pem);
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.count());
    const leaf = chain.leaf().?;
    try std.testing.expect(leaf.isSelfSigned());

    // SAN covers 127.0.0.1 and localhost.
    try verifyHostname(leaf.parsed, "127.0.0.1");
    try verifyHostname(leaf.parsed, "localhost");
    try std.testing.expectError(TlsError.CertificateHostMismatch, verifyHostname(leaf.parsed, "example.com"));

    try std.testing.expect(!leaf.isExpired(1800000000));
    try std.testing.expect(leaf.isExpired(2200000000));
    try std.testing.expect(leaf.isNotYetValid(1700000000));
}

test "self-signed trust mode accepts the fixture, default mode rejects it" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var chain = try certMod.parseCertificateChainPem(a, localhost_cert_pem);
    defer chain.deinit();

    var permissive = trustStoreMod.TrustStore.init(a, io);
    defer permissive.deinit();
    permissive.mode = .selfSigned;
    try verifyCertificateChain(chain, &permissive, "127.0.0.1", 1800000000);

    var strict = trustStoreMod.TrustStore.init(a, io);
    defer strict.deinit();
    // Empty default store trusts nothing: must fail, never silently pass.
    try std.testing.expectError(TlsError.CertificateUntrusted, verifyCertificateChain(chain, &strict, "127.0.0.1", 1800000000));

    // Expired fixture fails even in permissive mode.
    try std.testing.expectError(TlsError.CertificateExpired, verifyCertificateChain(chain, &permissive, "127.0.0.1", 2200000000));
}

test "custom CA bundle trusts the fixture leaf" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var chain = try certMod.parseCertificateChainPem(a, localhost_cert_pem);
    defer chain.deinit();

    var ts = trustStoreMod.TrustStore.init(a, io);
    defer ts.deinit();
    try ts.addCertPem(localhost_cert_pem);
    try std.testing.expectEqual(@as(usize, 1), ts.count());
    try verifyCertificateChain(chain, &ts, "localhost", 1800000000);
}

test "system trust store loads without crashing the verifier" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = trustStoreMod.TrustStore.init(a, io);
    defer ts.deinit();
    // Environments without roots (minimal containers) report unavailability;
    // either outcome proves the load path is wired, not dead code.
    ts.loadSystemTrust() catch |err| {
        try std.testing.expectEqual(TlsError.TlsCaUnavailable, err);
        return;
    };
    try ts.loadSystemTrust(); // second call is a cached no-op
}
