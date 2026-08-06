//! TLS Extension Encoding and Decoding (RFC 8446 Section4.2)
//!
//! Handles every extension type used by httpx.zig's TLS handshake:
//!
//! - SNI (server_name, type 0)                          RFC 6066
//! - ALPN (application_layer_protocol_negotiation, 16)  RFC 7301
//! - supported_versions (43)                            RFC 8446
//! - key_share (51)                                     RFC 8446
//! - supported_groups (10)                              RFC 8422
//! - signature_algorithms (13)                          RFC 8446
//! - psk_key_exchange_modes (45)                        RFC 8446
//! - server_name (reads server-side, for vhost selection)

const std = @import("std");
const mem = std.mem;
const tls = std.crypto.tls;
const errors = @import("errors.zig");

// ALPN (RFC 7301)

/// Maximum number of ALPN protocol identifiers in a single extension.
pub const max_alpn_protocols = 16;
/// Maximum byte length of a single ALPN protocol identifier.
pub const max_alpn_proto_len = 255;

/// Calculates the number of bytes needed to encode the ALPN
/// protocol list (the `ProtocolNameList` value field only  --
/// not including the outer extension type/length header).
///
/// Wire format (for a list of N protocols):
///   2 bytes: total list length
///   For each protocol:
///     1 byte:  protocol name length
///     N bytes: protocol name
pub fn alpnListEncodedLen(protocols: []const []const u8) usize {
    var len: usize = 2; // list-length field
    for (protocols) |p| {
        len += 1 + p.len;
    }
    return len;
}

/// Returns the total byte length of a complete ALPN extension, including
/// the 2-byte type, 2-byte extension-data length, and the ProtocolNameList.
pub fn alpnExtensionLen(protocols: []const []const u8) usize {
    return 2 + 2 + alpnListEncodedLen(protocols);
}

/// Writes the ALPN extension into `out` and returns the number of bytes
/// written.  `out` must be at least `alpnExtensionLen(protocols)` bytes.
///
/// Error: `TlsBufferTooSmall` if `out` is too short.
pub fn writeAlpnExtension(out: []u8, protocols: []const []const u8) errors.TlsError!usize {
    const needed = alpnExtensionLen(protocols);
    if (out.len < needed) return error.TlsBufferTooSmall;
    var off: usize = 0;
    // Extension type: application_layer_protocol_negotiation = 0x0010
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.application_layer_protocol_negotiation), .big);
    off += 2;
    // Extension data length (list-length field + protocol bytes).
    const list_len = alpnListEncodedLen(protocols);
    mem.writeInt(u16, out[off..][0..2], @intCast(list_len), .big);
    off += 2;
    // ProtocolNameList: 2-byte total length.
    const proto_bytes = list_len - 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(proto_bytes), .big);
    off += 2;
    // Each ProtocolName: 1-byte length + name bytes.
    for (protocols) |p| {
        out[off] = @intCast(p.len);
        off += 1;
        @memcpy(out[off..][0..p.len], p);
        off += p.len;
    }
    return off;
}

/// Parses an ALPN extension value (the extension data only, without the
/// extension type/length header) and stores matched protocols into `out`.
///
/// Returns the number of protocol strings stored in `out`.
/// Each returned slice points into `data`, so `data` must outlive `out`.
pub fn parseAlpnExtension(data: []const u8, out: *[max_alpn_protocols][]const u8) errors.TlsError!usize {
    if (data.len < 2) return error.TlsMalformedExtension;
    const list_len = mem.readInt(u16, data[0..2], .big);
    if (list_len + 2 > data.len) return error.TlsMalformedExtension;
    var off: usize = 2;
    var n: usize = 0;
    while (off < 2 + @as(usize, list_len)) {
        if (off >= data.len) return error.TlsMalformedExtension;
        const plen = data[off];
        off += 1;
        if (off + plen > data.len) return error.TlsMalformedExtension;
        if (n >= max_alpn_protocols) return error.TlsBufferTooSmall;
        out[n] = data[off..][0..plen];
        n += 1;
        off += plen;
    }
    return n;
}

// SNI (RFC 6066)

/// Returns the total byte length of an SNI extension (type + length + data).
pub fn sniExtensionLen(host: []const u8) usize {
    // type(2) + ext-data-len(2) + list-len(2) + name-type(1) + name-len(2) + name
    return 2 + 2 + 2 + 1 + 2 + host.len;
}

/// Writes an SNI extension for `host` into `out`.
/// Returns the number of bytes written.
pub fn writeSniExtension(out: []u8, host: []const u8) errors.TlsError!usize {
    const needed = sniExtensionLen(host);
    if (out.len < needed) return error.TlsBufferTooSmall;
    var off: usize = 0;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.server_name), .big);
    off += 2;
    // Extension data length.
    mem.writeInt(u16, out[off..][0..2], @intCast(2 + 1 + 2 + host.len), .big);
    off += 2;
    // ServerNameList length.
    mem.writeInt(u16, out[off..][0..2], @intCast(1 + 2 + host.len), .big);
    off += 2;
    // NameType: host_name = 0.
    out[off] = 0x00;
    off += 1;
    // HostName length + bytes.
    mem.writeInt(u16, out[off..][0..2], @intCast(host.len), .big);
    off += 2;
    @memcpy(out[off..][0..host.len], host);
    off += host.len;
    return off;
}

/// Parses an SNI extension value, storing the first hostname into `out_host`
/// (a slice into `data`).  Returns `true` if a host_name entry was found.
pub fn parseSniExtension(data: []const u8, out_host: *[]const u8) bool {
    if (data.len < 2) return false;
    var off: usize = 0;
    const list_len = mem.readInt(u16, data[off..][0..2], .big);
    off += 2;
    if (off + list_len > data.len) return false;
    const end = off + list_len;
    while (off < end) {
        if (off + 3 > end) return false;
        const name_type = data[off];
        off += 1;
        const name_len = mem.readInt(u16, data[off..][0..2], .big);
        off += 2;
        if (off + name_len > end) return false;
        if (name_type == 0x00) { // host_name
            out_host.* = data[off..][0..name_len];
            return true;
        }
        off += name_len;
    }
    return false;
}

// supported_versions (RFC 8446 Section4.2.1)

/// Returns the byte length of a `supported_versions` extension listing
/// TLS 1.3 and TLS 1.2 (client-side).
pub const supported_versions_client_len: usize = 2 + 2 + 1 + 2 * 2;

/// Writes the `supported_versions` client extension (TLS 1.3 first, then 1.2).
pub fn writeSupportedVersionsClient(out: []u8) errors.TlsError!usize {
    if (out.len < supported_versions_client_len) return error.TlsBufferTooSmall;
    var off: usize = 0;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.supported_versions), .big);
    off += 2;
    // Extension data length.
    mem.writeInt(u16, out[off..][0..2], 1 + 2 * 2, .big);
    off += 2;
    // Version list length (1 byte in client hello).
    out[off] = 2 * 2; // 2 versions x 2 bytes
    off += 1;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    return off;
}

// supported_groups (RFC 8422)

/// Named groups we advertise, in preference order.
pub const preferred_groups = [_]tls.NamedGroup{
    .x25519,
    .secp256r1,
    .secp384r1,
};

/// Returns the byte length of a `supported_groups` extension.
pub const supported_groups_ext_len: usize = 2 + 2 + 2 + preferred_groups.len * 2;

/// Writes the `supported_groups` extension.
pub fn writeSupportedGroupsExtension(out: []u8) errors.TlsError!usize {
    if (out.len < supported_groups_ext_len) return error.TlsBufferTooSmall;
    var off: usize = 0;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.supported_groups), .big);
    off += 2;
    const list_bytes = preferred_groups.len * 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(2 + list_bytes), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(list_bytes), .big);
    off += 2;
    for (preferred_groups) |g| {
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(g), .big);
        off += 2;
    }
    return off;
}

// signature_algorithms (RFC 8446 Section4.2.3)

pub const preferred_sig_algs = [_]tls.SignatureScheme{
    .ecdsa_secp256r1_sha256,
    .ecdsa_secp384r1_sha384,
    .rsa_pss_rsae_sha256,
    .rsa_pss_rsae_sha384,
    .rsa_pss_rsae_sha512,
    .rsa_pkcs1_sha256,
    .rsa_pkcs1_sha384,
    .rsa_pkcs1_sha512,
    .ed25519,
};

/// Returns the byte length of a `signature_algorithms` extension.
pub const sig_algs_ext_len: usize = 2 + 2 + 2 + preferred_sig_algs.len * 2;

/// Writes the `signature_algorithms` extension.
pub fn writeSignatureAlgorithmsExtension(out: []u8) errors.TlsError!usize {
    if (out.len < sig_algs_ext_len) return error.TlsBufferTooSmall;
    var off: usize = 0;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.signature_algorithms), .big);
    off += 2;
    const list_bytes = preferred_sig_algs.len * 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(2 + list_bytes), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(list_bytes), .big);
    off += 2;
    for (preferred_sig_algs) |s| {
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(s), .big);
        off += 2;
    }
    return off;
}

// psk_key_exchange_modes (RFC 8446 Section4.2.9)

pub const psk_modes_ext: [8]u8 = blk: {
    var b: [8]u8 = undefined;
    // type = psk_key_exchange_modes
    mem.writeIntBig(u16, b[0..2], @intFromEnum(tls.ExtensionType.psk_key_exchange_modes));
    // ext-data-len = 2 (1-byte list-len + 1-byte mode)
    mem.writeIntBig(u16, b[2..4], 2);
    b[4] = 1; // list length
    b[5] = @intFromEnum(tls.PskKeyExchangeMode.psk_dhe_ke);
    b[6] = 0;
    b[7] = 0; // padding to fill the array (not sent)
    break :blk b;
};

/// Writes the `psk_key_exchange_modes` extension (6 bytes).
pub fn writePskKeyExchangeModesExtension(out: []u8) errors.TlsError!usize {
    if (out.len < 6) return error.TlsBufferTooSmall;
    mem.writeInt(u16, out[0..2], @intFromEnum(tls.ExtensionType.psk_key_exchange_modes), .big);
    mem.writeInt(u16, out[2..4], 2, .big);
    out[4] = 1; // list length
    out[5] = @intFromEnum(tls.PskKeyExchangeMode.psk_dhe_ke);
    return 6;
}

// Tests

test "ALPN encode-decode round-trip" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const protocols: []const []const u8 = &.{ "h2", "http/1.1" };
    const written = try writeAlpnExtension(&buf, protocols);
    // The extension starts with type (2) + data-len (2).
    try t.expectEqual(@as(u16, @intFromEnum(tls.ExtensionType.application_layer_protocol_negotiation)), mem.readInt(u16, buf[0..2], .big));
    // Parse back the extension data (skip type+data-len header = 4 bytes).
    const ext_data_len = mem.readInt(u16, buf[2..4], .big);
    var decoded: [max_alpn_protocols][]const u8 = undefined;
    const n = try parseAlpnExtension(buf[4..][0..ext_data_len], &decoded);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqualStrings("h2", decoded[0]);
    try t.expectEqualStrings("http/1.1", decoded[1]);
    _ = written;
}

test "SNI encode-decode round-trip" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const host = "example.com";
    const written = try writeSniExtension(&buf, host);
    // Skip type + ext-data-len = 4 bytes; then list-len = 2 bytes.
    var out_host: []const u8 = "";
    const found = parseSniExtension(buf[4..written], &out_host);
    try t.expect(found);
    try t.expectEqualStrings(host, out_host);
}

test "supported_versions client extension" {
    var buf: [16]u8 = undefined;
    const n = try writeSupportedVersionsClient(&buf);
    try std.testing.expectEqual(supported_versions_client_len, n);
}

test "alpnListEncodedLen" {
    const protocols: []const []const u8 = &.{ "h2", "http/1.1" };
    // 2 (list-len) + (1+2) + (1+8) = 2 + 3 + 9 = 14
    try std.testing.expectEqual(@as(usize, 14), alpnListEncodedLen(protocols));
}

test "alpnExtensionLen" {
    const protocols: []const []const u8 = &.{ "h2", "http/1.1" };
    // 2 (type) + 2 (data-len) + 14 (list) = 18
    try std.testing.expectEqual(@as(usize, 18), alpnExtensionLen(protocols));
}

test "writeAlpnExtension single protocol" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const protocols: []const []const u8 = &.{"h2"};
    const written = try writeAlpnExtension(&buf, protocols);
    try t.expect(written > 0);
    // Parse back
    const ext_data_len = mem.readInt(u16, buf[2..4], .big);
    var decoded: [max_alpn_protocols][]const u8 = undefined;
    const n = try parseAlpnExtension(buf[4..][0..ext_data_len], &decoded);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqualStrings("h2", decoded[0]);
}

test "writeAlpnExtension buffer too small" {
    var buf: [2]u8 = undefined;
    const protocols: []const []const u8 = &.{"h2"};
    const result = writeAlpnExtension(&buf, protocols);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "parseAlpnExtension rejects short data" {
    var buf: [1]u8 = [_]u8{0};
    var decoded: [max_alpn_protocols][]const u8 = undefined;
    const result = parseAlpnExtension(&buf, &decoded);
    try std.testing.expectError(error.TlsMalformedExtension, result);
}

test "writeSniExtension buffer too small" {
    var buf: [2]u8 = undefined;
    const result = writeSniExtension(&buf, "example.com");
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "sniExtensionLen matches actual write" {
    const host = "example.com";
    const expected = sniExtensionLen(host);
    var buf: [128]u8 = undefined;
    const written = try writeSniExtension(&buf, host);
    try std.testing.expectEqual(expected, written);
}

test "parseSniExtension returns false for empty data" {
    var out_host: []const u8 = "";
    const result = parseSniExtension(&.{}, &out_host);
    try std.testing.expect(!result);
}

test "writeSupportedGroupsExtension" {
    var buf: [64]u8 = undefined;
    const n = try writeSupportedGroupsExtension(&buf);
    try std.testing.expectEqual(supported_groups_ext_len, n);
    // Verify extension type
    const ext_type = mem.readInt(u16, buf[0..2], .big);
    try std.testing.expectEqual(@intFromEnum(tls.ExtensionType.supported_groups), ext_type);
}

test "writeSupportedGroupsExtension buffer too small" {
    var buf: [4]u8 = undefined;
    const result = writeSupportedGroupsExtension(&buf);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "writeSignatureAlgorithmsExtension" {
    var buf: [64]u8 = undefined;
    const n = try writeSignatureAlgorithmsExtension(&buf);
    try std.testing.expectEqual(sig_algs_ext_len, n);
    const ext_type = mem.readInt(u16, buf[0..2], .big);
    try std.testing.expectEqual(@intFromEnum(tls.ExtensionType.signature_algorithms), ext_type);
}

test "writeSignatureAlgorithmsExtension buffer too small" {
    var buf: [4]u8 = undefined;
    const result = writeSignatureAlgorithmsExtension(&buf);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "writePskKeyExchangeModesExtension" {
    var buf: [8]u8 = undefined;
    const n = try writePskKeyExchangeModesExtension(&buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    const ext_type = mem.readInt(u16, buf[0..2], .big);
    try std.testing.expectEqual(@intFromEnum(tls.ExtensionType.psk_key_exchange_modes), ext_type);
}

test "writePskKeyExchangeModesExtension buffer too small" {
    var buf: [4]u8 = undefined;
    const result = writePskKeyExchangeModesExtension(&buf);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "writeSupportedVersionsClient buffer too small" {
    var buf: [4]u8 = undefined;
    const result = writeSupportedVersionsClient(&buf);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "supported_versions extension contains TLS 1.3 and 1.2" {
    var buf: [16]u8 = undefined;
    const n = try writeSupportedVersionsClient(&buf);
    // Skip type + data-len = 4 bytes, then list-len = 1 byte
    const ver1 = mem.readInt(u16, buf[5..7], .big);
    const ver2 = mem.readInt(u16, buf[7..9], .big);
    try std.testing.expectEqual(@intFromEnum(tls.ProtocolVersion.tls_1_3), ver1);
    try std.testing.expectEqual(@intFromEnum(tls.ProtocolVersion.tls_1_2), ver2);
    _ = n;
}
