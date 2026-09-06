//! QUIC-TLS key derivation (RFC 9001).
//!
//! Initial packet secrets are derived from the destination connection ID
//! using HKDF-SHA256 with the version-specific salts. Application secrets
//! arrive from the TLS 1.3 handshake layer (see tls_engine.zig); this
//! module provides the QUIC-specific label machinery both paths share.
//!
//! Constants verified against ngtcp2/lib/ngtcp2_crypto/shared.c.

const std = @import("std");
const hmac = std.crypto.auth.hmac;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

pub const Error = error{UnsupportedVersion};

/// QUIC v1 initial salt.
pub const initial_salt_v1 = [_]u8{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a,
};

/// QUIC v2 initial salt (RFC 9369).
pub const initial_salt_v2 = [_]u8{
    0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb,
    0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb,
    0xf9, 0xbd, 0x2e, 0xd9,
};

pub fn saltForVersion(version: u32) Error![20]u8 {
    return switch (version) {
        0x00000001 => initial_salt_v1,
        0x6B3343CF => initial_salt_v2,
        else => Error.UnsupportedVersion,
    };
}

/// HKDF-Expand-Label from TLS 1.3 (RFC 8446 section 7.1):
/// info = uint16(len) || uint8(6 + label.len) || "tls13 " || label || 0x00
pub fn hkdfExpandLabel(prk: [32]u8, comptime label: []const u8, out: []u8) void {
    const full_label = "tls13 " ++ label;
    var info_buf: [2 + 1 + 64 + 1]u8 = undefined;
    const info_len = 2 + 1 + full_label.len + 1;
    var w: usize = 0;

    const total: u16 = @intCast(out.len);
    info_buf[w] = @intCast(total >> 8);
    info_buf[w + 1] = @intCast(total & 0xFF);
    w += 2;
    info_buf[w] = @intCast(full_label.len);
    w += 1;
    @memcpy(info_buf[w..][0..full_label.len], full_label);
    w += full_label.len;
    info_buf[w] = 0;
    w += 1;

    HkdfSha256.expand(out, info_buf[0..info_len], prk);
}

/// Derives a secret from a parent secret with a label suffix
/// ("client in"/"server in"/"quic ku"...).
pub fn deriveSecret(prk: [32]u8, comptime label: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    hkdfExpandLabel(prk, label, &out);
    return out;
}

pub const Cipher = enum { aes_128_gcm, aes_256_gcm, chacha20_poly1305 };

/// Packet-protection keys for one direction at one encryption level.
pub const ProtectionKeys = struct {
    /// AEAD key (16 bytes for AES-128-GCM, 32 for AES-256-GCM/ChaCha20-Poly1305).
    key: [32]u8 = [_]u8{0} ** 32,
    key_len: usize = 16,
    /// Nonce construction IV (12 bytes).
    iv: [12]u8,
    /// Header-protection key (16 bytes for AES, 32 for ChaCha20).
    hp: [32]u8 = [_]u8{0} ** 32,
    hp_len: usize = 16,
    cipher: Cipher = .aes_128_gcm,

    pub const key_len_128 = 16;
    pub const key_len_256 = 32;
    pub const iv_len = 12;
};

/// Derives {key, iv, hp} from a secret using QUIC labels (AES-128-GCM, 16-byte key).
pub fn deriveProtectionKeys(secret: [32]u8) ProtectionKeys {
    var pk: ProtectionKeys = .{ .iv = undefined, .hp = undefined, .cipher = .aes_128_gcm };
    pk.key_len = 16;
    pk.hp_len = 16;
    hkdfExpandLabel(secret, "quic key", pk.key[0..16]);
    hkdfExpandLabel(secret, "quic iv", pk.iv[0..]);
    hkdfExpandLabel(secret, "quic hp", pk.hp[0..16]);
    @memset(pk.key[16..], 0);
    @memset(pk.hp[16..], 0);
    return pk;
}

/// Derives {key, iv, hp} for the negotiated 1-RTT cipher.
pub fn deriveProtectionKeysForCipher(secret: [32]u8, cipher: Cipher) ProtectionKeys {
    var pk: ProtectionKeys = .{ .iv = undefined, .hp = undefined, .cipher = cipher };
    switch (cipher) {
        .aes_128_gcm => {
            pk.key_len = 16;
            pk.hp_len = 16;
            hkdfExpandLabel(secret, "quic key", pk.key[0..16]);
            @memset(pk.key[16..], 0);
            hkdfExpandLabel(secret, "quic hp", pk.hp[0..16]);
            @memset(pk.hp[16..], 0);
        },
        .aes_256_gcm => {
            pk.key_len = 32;
            pk.hp_len = 16;
            hkdfExpandLabel(secret, "quic key", pk.key[0..32]);
            hkdfExpandLabel(secret, "quic hp", pk.hp[0..16]);
            @memset(pk.hp[16..], 0);
        },
        .chacha20_poly1305 => {
            pk.key_len = 32;
            pk.hp_len = 32;
            hkdfExpandLabel(secret, "quic key", pk.key[0..32]);
            hkdfExpandLabel(secret, "quic hp", pk.hp[0..32]);
        },
    }
    hkdfExpandLabel(secret, "quic iv", pk.iv[0..]);
    return pk;
}

pub const InitialSecrets = struct {
    client: [32]u8,
    server: [32]u8,
};

/// Computes the Initial secrets for a destination connection ID.
pub fn initialSecrets(dcid: []const u8, version: u32) Error!InitialSecrets {
    const salt = try saltForVersion(version);
    const initial_secret = HkdfSha256.extract(&salt, dcid);
    return .{
        .client = deriveSecret(initial_secret, "client in"),
        .server = deriveSecret(initial_secret, "server in"),
    };
}

/// Convenience: protection keys for one side of the Initial space.
pub fn initialProtection(secrets: InitialSecrets, side: enum { client, server }) ProtectionKeys {
    return switch (side) {
        .client => deriveProtectionKeys(secrets.client),
        .server => deriveProtectionKeys(secrets.server),
    };
}

/// Key update (RFC 9001 section 6): next application secret.
pub fn nextApplicationSecret(current: [32]u8) [32]u8 {
    return deriveSecret(current, "quic ku");
}

// Tests

test "hkdfExpandLabel produces tls13-prefixed info" {
    // Structural check: same prk+label yields deterministic equal output.
    var prk: [32]u8 = .{0xAB} ** 32;
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    hkdfExpandLabel(prk, "quic key", a[0..]);
    hkdfExpandLabel(prk, "quic key", b[0..]);
    try std.testing.expectEqualSlices(u8, &a, &b);

    // Different labels differ.
    var c: [16]u8 = undefined;
    hkdfExpandLabel(prk, "quic iv", c[0..]);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    _ = &prk;
}

test "RFC 9001 A.1/A.2 initial secrets and keys (authoritative vectors)" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const sec = try initialSecrets(&dcid, 0x00000001);

    // client_initial_secret
    const want_client = [_]u8{
        0xc0, 0x0c, 0xf1, 0x51, 0xca, 0x5b, 0xe0, 0x75,
        0xed, 0x0e, 0xbf, 0xb5, 0xc8, 0x03, 0x23, 0xc4,
        0x2d, 0x6b, 0x7d, 0xb6, 0x78, 0x81, 0x28, 0x9a,
        0xf4, 0x00, 0x8f, 0x1f, 0x6c, 0x35, 0x7a, 0xea,
    };
    // server_initial_secret
    const want_server = [_]u8{
        0x3c, 0x19, 0x98, 0x28, 0xfd, 0x13, 0x9e, 0xfd,
        0x21, 0x6c, 0x15, 0x5a, 0xd8, 0x44, 0xcc, 0x81,
        0xfb, 0x82, 0xfa, 0x8d, 0x74, 0x46, 0xfa, 0x7d,
        0x78, 0xbe, 0x80, 0x3a, 0xcd, 0xda, 0x95, 0x1b,
    };
    try std.testing.expectEqualSlices(u8, &want_client, &sec.client);
    try std.testing.expectEqualSlices(u8, &want_server, &sec.server);

    const cpk = initialProtection(sec, .client);
    const spk = initialProtection(sec, .server);

    const want_ckey = [_]u8{ 0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d };
    const want_civ = [_]u8{ 0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c };
    const want_chp = [_]u8{ 0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2 };
    const want_skey = [_]u8{ 0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c, 0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37 };
    const want_siv = [_]u8{ 0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53, 0xb0, 0xbb, 0xa0, 0x3e };
    const want_shp = [_]u8{ 0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76, 0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14 };

    try std.testing.expectEqualSlices(u8, &want_ckey, cpk.key[0..16]);
    try std.testing.expectEqualSlices(u8, &want_civ, &cpk.iv);
    try std.testing.expectEqualSlices(u8, &want_chp, cpk.hp[0..16]);
    try std.testing.expectEqualSlices(u8, &want_skey, spk.key[0..16]);
    try std.testing.expectEqualSlices(u8, &want_siv, &spk.iv);
    try std.testing.expectEqualSlices(u8, &want_shp, spk.hp[0..16]);
}
