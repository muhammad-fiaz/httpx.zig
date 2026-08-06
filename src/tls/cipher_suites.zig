//! TLS Cipher Suite Registry
//!
//! Maps `std.crypto.tls.CipherSuite` identifiers to the corresponding
//! AEAD and hash algorithm types from `std.crypto`, and provides priority
//! ordering for handshake negotiation.
//!
//! Only AEAD cipher suites are supported (CBC-mode suites are NOT included,
//! as they are deprecated, insecure in TLS 1.2, and absent from TLS 1.3).

const std = @import("std");
const crypto = std.crypto;
const tls = std.crypto.tls;

/// A resolved cipher suite: concrete AEAD and Hash types available at
/// comptime, plus the wire identifier.
pub const SuiteInfo = struct {
    id: tls.CipherSuite,
    /// Human-readable name for logging / diagnostics.
    name: []const u8,
    /// TLS version compatibility.
    tls13_only: bool,
};

/// Ordered list of cipher suites we advertise in ClientHello, most
/// preferred first.  All suites listed here are AEAD-based.
///
/// TLS 1.3 suites come first because any TLS 1.3 handshake must only
/// use the first group.  TLS 1.2 ECDHE-AEAD suites follow.
pub const preferred_suites = [_]tls.CipherSuite{
    // TLS 1.3 suites (RFC 8446 B.4)
    .AES_128_GCM_SHA256,
    .AES_256_GCM_SHA384,
    .CHACHA20_POLY1305_SHA256,
    .AEGIS_256_SHA512,
    .AEGIS_128L_SHA256,
    // TLS 1.2 ECDHE+AEAD suites (RFC 5289)
    .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
};

/// Returns static metadata for a suite, or null if unrecognised / unsupported.
pub fn suiteInfo(id: tls.CipherSuite) ?SuiteInfo {
    return switch (id) {
        .AES_128_GCM_SHA256 => .{ .id = id, .name = "TLS_AES_128_GCM_SHA256", .tls13_only = true },
        .AES_256_GCM_SHA384 => .{ .id = id, .name = "TLS_AES_256_GCM_SHA384", .tls13_only = true },
        .CHACHA20_POLY1305_SHA256 => .{ .id = id, .name = "TLS_CHACHA20_POLY1305_SHA256", .tls13_only = true },
        .AEGIS_256_SHA512 => .{ .id = id, .name = "TLS_AEGIS_256_SHA512", .tls13_only = true },
        .AEGIS_128L_SHA256 => .{ .id = id, .name = "TLS_AEGIS_128L_SHA256", .tls13_only = true },
        .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => .{ .id = id, .name = "ECDHE-RSA-AES128-GCM-SHA256", .tls13_only = false },
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => .{ .id = id, .name = "ECDHE-RSA-AES256-GCM-SHA384", .tls13_only = false },
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => .{ .id = id, .name = "ECDHE-RSA-CHACHA20-POLY1305", .tls13_only = false },
        else => null,
    };
}

/// Returns true if `id` is a TLS 1.3-only cipher suite.
pub fn isTls13Only(id: tls.CipherSuite) bool {
    return switch (id) {
        .AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
        .CHACHA20_POLY1305_SHA256,
        .AEGIS_256_SHA512,
        .AEGIS_128L_SHA256,
        => true,
        else => false,
    };
}

/// Returns true if `id` is in our supported set.
pub fn isSupported(id: tls.CipherSuite) bool {
    for (&preferred_suites) |s| {
        if (s == id) return true;
    }
    return false;
}

/// Serialises the preferred cipher suite list into the wire format
/// expected in a ClientHello `cipher_suites` field.
///
/// Wire format: 2-byte list length, then 2 bytes per suite ID (big-endian).
/// Returns the number of bytes written.
pub fn writeCipherSuiteList(buf: []u8) usize {
    // The list includes TLS 1.3 + TLS 1.2 suites, plus the signalling SCSV.
    const suites_to_write = preferred_suites ++ [_]tls.CipherSuite{
        .EMPTY_RENEGOTIATION_INFO_SCSV,
    };
    const list_len: u16 = @intCast(suites_to_write.len * 2);
    std.mem.writeInt(u16, buf[0..2], list_len, .big);
    var off: usize = 2;
    for (suites_to_write) |s| {
        std.mem.writeInt(u16, buf[off..][0..2], @intFromEnum(s), .big);
        off += 2;
    }
    return off;
}

/// Total byte length of our cipher suite list (list-length field + ids).
pub const cipher_suite_list_len: usize = 2 + (preferred_suites.len + 1) * 2;

test "writeCipherSuiteList" {
    var buf: [512]u8 = undefined;
    const n = writeCipherSuiteList(&buf);
    try std.testing.expect(n > 2);
    // First two bytes are the list length.
    const list_len = std.mem.readInt(u16, buf[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intCast(n - 2)), list_len);
}

test "suiteInfo known suites" {
    try std.testing.expect(suiteInfo(.AES_128_GCM_SHA256) != null);
    try std.testing.expect(suiteInfo(.CHACHA20_POLY1305_SHA256) != null);
    try std.testing.expect(suiteInfo(.RSA_WITH_AES_128_CBC_SHA) == null);
}

test "isTls13Only" {
    try std.testing.expect(isTls13Only(.AES_128_GCM_SHA256));
    try std.testing.expect(!isTls13Only(.ECDHE_RSA_WITH_AES_128_GCM_SHA256));
}

test "isSupported all preferred suites" {
    for (preferred_suites) |s| {
        try std.testing.expect(isSupported(s));
    }
}

test "isSupported unsupported suite" {
    try std.testing.expect(!isSupported(.RSA_WITH_AES_128_CBC_SHA));
}

test "suiteInfo name is non-empty for known suites" {
    const info = suiteInfo(.AES_128_GCM_SHA256);
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.name.len > 0);
}

test "suiteInfo tls13_only flag matches" {
    try std.testing.expect(suiteInfo(.AES_128_GCM_SHA256).?.tls13_only);
    try std.testing.expect(suiteInfo(.ECDHE_RSA_WITH_AES_128_GCM_SHA256).?.tls13_only == false);
}

test "cipher_suite_list_len matches writeCipherSuiteList" {
    var buf: [512]u8 = undefined;
    const n = writeCipherSuiteList(&buf);
    try std.testing.expectEqual(cipher_suite_list_len, n);
}

test "writeCipherSuiteList includes EMPTY_RENEGOTIATION_INFO_SCSV" {
    var buf: [512]u8 = undefined;
    const n = writeCipherSuiteList(&buf);
    const list_len = std.mem.readInt(u16, buf[0..2], .big);
    const num_suites = list_len / 2;
    // preferred_suites.len + 1 (SCSV)
    try std.testing.expectEqual(@as(usize, preferred_suites.len + 1), num_suites);
    // Last entry should be EMPTY_RENEGOTIATION_INFO_SCSV
    const last_suite = std.mem.readInt(u16, buf[n - 2 ..][0..2], .big);
    try std.testing.expectEqual(@intFromEnum(tls.CipherSuite.EMPTY_RENEGOTIATION_INFO_SCSV), last_suite);
}
