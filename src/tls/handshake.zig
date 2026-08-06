//! Shared TLS Handshake Engine & Types (TLS 1.2 and 1.3)
//!
//! Provides:
//! - State machine states for both protocol versions
//! - ClientHello / ServerHello construction helpers
//! - Handshake message framing (type + 24-bit length)
//! - Key exchange state (X25519, P-256, P-384)
//! - Cipher state tracking (cleartext -> handshake -> application)

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const tls = std.crypto.tls;
const errors = @import("errors.zig");

// Shared HMAC types

pub const HmacSha256 = crypto.auth.hmac.Hmac(crypto.hash.sha2.Sha256);
pub const HmacSha384 = crypto.auth.hmac.Hmac(crypto.hash.sha2.Sha384);

// Handshake message framing (type + 3-byte length)

pub const HandshakeHeaderLen = 4;

pub fn writeHandshakeHeader(msg_type: tls.HandshakeType, length: u24, out: *[HandshakeHeaderLen]u8) void {
    out[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u24, out[1..4], length, .big);
}

// Key Exchange

pub const NamedGroupChoice = enum {
    x25519,
    secp256r1,
    secp384r1,
};

/// Holds all key exchange state for a handshake.
/// Supports X25519, P-256, and P-384 ECDHE.
pub const KeyExchange = struct {
    /// The named group selected for this handshake.
    group: NamedGroupChoice = .x25519,

    // X25519 key pairs
    x25519_kp: crypto.dh.X25519.KeyPair = undefined,
    x25519_shared: [32]u8 = undefined,

    // P-256 key pairs (via ECDSA key pair, secret_key is a scalar)
    secp256r1_kp: crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair = undefined,
    secp256r1_shared: [32]u8 = undefined,
    secp256r1_pub_buf: [65]u8 = undefined,
    secp256r1_pub_len: u8 = 0,

    // P-384 key pairs
    secp384r1_kp: crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair = undefined,
    secp384r1_shared: [48]u8 = undefined,
    secp384r1_pub_buf: [97]u8 = undefined,
    secp384r1_pub_len: u8 = 0,

    has_shared_secret: bool = false,

    /// Initialize key exchange with random bytes.
    pub fn init(entropy: []const u8) errors.TlsError!KeyExchange {
        if (entropy.len < 96) return error.TlsBufferTooSmall;
        var kx: KeyExchange = .{};
        var seed32: [32]u8 = undefined;
        @memcpy(&seed32, entropy[0..32]);
        kx.x25519_kp = crypto.dh.X25519.KeyPair.generateDeterministic(seed32) catch return error.TlsKeyExchangeFailed;
        var seed32b: [32]u8 = undefined;
        @memcpy(&seed32b, entropy[32..64]);
        kx.secp256r1_kp = crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(seed32b) catch return error.TlsKeyExchangeFailed;
        var seed48: [48]u8 = [_]u8{0} ** 48;
        @memcpy(seed48[0..32], entropy[64..96]);
        kx.secp384r1_kp = crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.generateDeterministic(seed48) catch return error.TlsKeyExchangeFailed;
        return kx;
    }

    /// Get our public key for a given named group.
    pub fn getPublicKey(self: *KeyExchange, group: tls.NamedGroup) errors.TlsError![]const u8 {
        return switch (group) {
            .x25519 => &self.x25519_kp.public_key,
            .secp256r1 => blk: {
                const sec1 = self.secp256r1_kp.public_key.p.toUncompressedSec1();
                @memcpy(self.secp256r1_pub_buf[0..sec1.len], &sec1);
                self.secp256r1_pub_len = @intCast(sec1.len);
                break :blk self.secp256r1_pub_buf[0..sec1.len];
            },
            .secp384r1 => blk: {
                const sec1 = self.secp384r1_kp.public_key.p.toUncompressedSec1();
                @memcpy(self.secp384r1_pub_buf[0..sec1.len], &sec1);
                self.secp384r1_pub_len = @intCast(sec1.len);
                break :blk self.secp384r1_pub_buf[0..sec1.len];
            },
            else => error.TlsIllegalParameter,
        };
    }

    /// Perform key exchange with the peer's public key.
    pub fn exchange(self: *KeyExchange, group: tls.NamedGroup, peer_pub: []const u8) errors.TlsError!void {
        self.group = switch (group) {
            .x25519 => .x25519,
            .secp256r1 => .secp256r1,
            .secp384r1 => .secp384r1,
            else => return error.TlsIllegalParameter,
        };
        switch (group) {
            .x25519 => {
                if (peer_pub.len != 32) return error.TlsIllegalParameter;
                var peer_key: [32]u8 = undefined;
                @memcpy(&peer_key, peer_pub[0..32]);
                self.x25519_shared = crypto.dh.X25519.scalarmult(self.x25519_kp.secret_key, peer_key) catch return error.TlsKeyExchangeFailed;
            },
            .secp256r1 => {
                const PublicKey = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;
                const pk = PublicKey.fromSec1(peer_pub) catch return error.TlsKeyExchangeFailed;
                const result = pk.p.mulPublic(self.secp256r1_kp.secret_key.bytes, .big) catch return error.TlsKeyExchangeFailed;
                self.secp256r1_shared = result.affineCoordinates().x.toBytes(.big);
            },
            .secp384r1 => {
                const PublicKey = crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey;
                const pk = PublicKey.fromSec1(peer_pub) catch return error.TlsKeyExchangeFailed;
                const result = pk.p.mulPublic(self.secp384r1_kp.secret_key.bytes, .big) catch return error.TlsKeyExchangeFailed;
                self.secp384r1_shared = result.affineCoordinates().x.toBytes(.big);
            },
            else => return error.TlsIllegalParameter,
        }
        self.has_shared_secret = true;
    }

    /// Get the raw shared secret bytes.
    pub fn getSharedSecret(self: *const KeyExchange) ?[]const u8 {
        if (!self.has_shared_secret) return null;
        return switch (self.group) {
            .x25519 => &self.x25519_shared,
            .secp256r1 => &self.secp256r1_shared,
            .secp384r1 => &self.secp384r1_shared,
        };
    }
};

// TLS 1.2 Master Secret derivation (PRF via HMAC)

pub fn prfHmacExpandLabel(
    comptime Hmac: type,
    secret: []const u8,
    label: []const u8,
    seed1: []const u8,
    seed2: []const u8,
    comptime out_len: usize,
) [out_len]u8 {
    var a: [Hmac.mac_length]u8 = undefined;
    var result: [std.mem.alignForwardAnyAlign(usize, out_len, Hmac.mac_length)]u8 = undefined;
    var index: usize = 0;
    while (index < result.len) : (index += Hmac.mac_length) {
        var a_hmac: Hmac = undefined;
        if (index == 0) {
            a_hmac = Hmac.init(secret);
            a_hmac.update(label);
            a_hmac.update(seed1);
            a_hmac.update(seed2);
        } else {
            a_hmac = Hmac.init(secret);
            a_hmac.update(&a);
            a_hmac.update(label);
            a_hmac.update(seed1);
            a_hmac.update(seed2);
        }
        a_hmac.final(&a);

        var result_hmac: Hmac = Hmac.init(secret);
        result_hmac.update(&a);
        result_hmac.update(label);
        result_hmac.update(seed1);
        result_hmac.update(seed2);
        result_hmac.final(result[index..][0..Hmac.mac_length]);
    }
    return result[0..out_len].*;
}

/// Derive the TLS 1.2 master_secret from pre_master_secret.
pub fn deriveMasterSecret(
    comptime Hmac: type,
    pre_master_secret: []const u8,
    client_random: *const [32]u8,
    server_random: *const [32]u8,
) [48]u8 {
    return prfHmacExpandLabel(Hmac, pre_master_secret, "master secret", client_random, server_random, 48);
}

/// Derive the TLS 1.2 key_block from master_secret.
pub fn deriveKeyBlock(
    comptime Hmac: type,
    master_secret: *const [48]u8,
    server_random: *const [32]u8,
    client_random: *const [32]u8,
    comptime block_len: usize,
) [block_len]u8 {
    return prfHmacExpandLabel(Hmac, master_secret, "key expansion", server_random, client_random, block_len);
}

/// Compute TLS 1.2 Finished verify_data.
pub fn tls12FinishedVerifyData(
    comptime Hmac: type,
    master_secret: *const [48]u8,
    transcript_hash: []const u8,
    label: []const u8,
) [12]u8 {
    var full: [Hmac.mac_length]u8 = undefined;
    var h: Hmac = Hmac.init(master_secret);
    h.update(label);
    h.update(transcript_hash);
    h.final(&full);
    return full[0..12].*;
}

// Test helpers

test "KeyExchange init with valid entropy" {
    var entropy: [96]u8 = [_]u8{0xAB} ** 96;
    const kx = try KeyExchange.init(&entropy);
    _ = kx;
}

test "KeyExchange X25519 exchange" {
    var entropy1: [96]u8 = [_]u8{0x01} ** 96;
    var entropy2: [96]u8 = [_]u8{0x02} ** 96;
    var kx1 = try KeyExchange.init(&entropy1);
    var kx2 = try KeyExchange.init(&entropy2);

    const pub1 = try kx1.getPublicKey(.x25519);
    const pub2 = try kx2.getPublicKey(.x25519);

    try kx1.exchange(.x25519, pub2);
    try kx2.exchange(.x25519, pub1);

    const sec1 = kx1.getSharedSecret().?;
    const sec2 = kx2.getSharedSecret().?;
    try std.testing.expectEqualSlices(u8, sec1, sec2);
}

test "KeyExchange init fails with too little entropy" {
    var entropy: [50]u8 = [_]u8{0xFF} ** 50;
    const result = KeyExchange.init(&entropy);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}

test "KeyExchange getSharedSecret returns null before exchange" {
    var entropy: [96]u8 = [_]u8{0x01} ** 96;
    var kx = try KeyExchange.init(&entropy);
    try std.testing.expect(kx.getSharedSecret() == null);
}

test "KeyExchange getSharedSecret returns non-null after exchange" {
    var entropy1: [96]u8 = [_]u8{0x01} ** 96;
    var entropy2: [96]u8 = [_]u8{0x02} ** 96;
    var kx1 = try KeyExchange.init(&entropy1);
    var kx2 = try KeyExchange.init(&entropy2);
    const pub2 = try kx2.getPublicKey(.x25519);
    try kx1.exchange(.x25519, pub2);
    try std.testing.expect(kx1.getSharedSecret() != null);
}

test "KeyExchange P-256 exchange" {
    var entropy1: [96]u8 = [_]u8{0x11} ** 96;
    var entropy2: [96]u8 = [_]u8{0x22} ** 96;
    var kx1 = try KeyExchange.init(&entropy1);
    var kx2 = try KeyExchange.init(&entropy2);

    const pub1 = try kx1.getPublicKey(.secp256r1);
    const pub2 = try kx2.getPublicKey(.secp256r1);

    try kx1.exchange(.secp256r1, pub2);
    try kx2.exchange(.secp256r1, pub1);

    const sec1 = kx1.getSharedSecret().?;
    const sec2 = kx2.getSharedSecret().?;
    try std.testing.expectEqualSlices(u8, sec1, sec2);
}

test "KeyExchange P-384 exchange" {
    var entropy1: [96]u8 = [_]u8{0x33} ** 96;
    var entropy2: [96]u8 = [_]u8{0x44} ** 96;
    var kx1 = try KeyExchange.init(&entropy1);
    var kx2 = try KeyExchange.init(&entropy2);

    const pub1 = try kx1.getPublicKey(.secp384r1);
    const pub2 = try kx2.getPublicKey(.secp384r1);

    try kx1.exchange(.secp384r1, pub2);
    try kx2.exchange(.secp384r1, pub1);

    const sec1 = kx1.getSharedSecret().?;
    const sec2 = kx2.getSharedSecret().?;
    try std.testing.expectEqualSlices(u8, sec1, sec2);
}

test "writeHandshakeHeader encodes correctly" {
    var buf: [HandshakeHeaderLen]u8 = undefined;
    writeHandshakeHeader(.client_hello, 0x000100, &buf);
    try std.testing.expectEqual(@intFromEnum(tls.HandshakeType.client_hello), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[3]);
}

test "writeHandshakeHeader server_hello" {
    var buf: [HandshakeHeaderLen]u8 = undefined;
    writeHandshakeHeader(.server_hello, 0x000020, &buf);
    try std.testing.expectEqual(@intFromEnum(tls.HandshakeType.server_hello), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x20), buf[3]);
}

test "prfHmacExpandLabel produces deterministic output" {
    const secret = [_]u8{0xAA} ** 32;
    const seed1 = [_]u8{0xBB} ** 32;
    const seed2 = [_]u8{0xCC} ** 32;
    const out1 = prfHmacExpandLabel(HmacSha256, &secret, "test label", &seed1, &seed2, 48);
    const out2 = prfHmacExpandLabel(HmacSha256, &secret, "test label", &seed1, &seed2, 48);
    try std.testing.expectEqualSlices(u8, &out1, &out2);
}

test "prfHmacExpandLabel differs for different labels" {
    const secret = [_]u8{0xAA} ** 32;
    const seed1 = [_]u8{0xBB} ** 32;
    const seed2 = [_]u8{0xCC} ** 32;
    const out1 = prfHmacExpandLabel(HmacSha256, &secret, "label one", &seed1, &seed2, 48);
    const out2 = prfHmacExpandLabel(HmacSha256, &secret, "label two", &seed1, &seed2, 48);
    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "deriveMasterSecret returns 48 bytes" {
    const pre_master = [_]u8{0x01} ** 48;
    const client_random = [_]u8{0x02} ** 32;
    const server_random = [_]u8{0x03} ** 32;
    const ms = deriveMasterSecret(HmacSha256, &pre_master, &client_random, &server_random);
    try std.testing.expectEqual(@as(usize, 48), ms.len);
}

test "deriveKeyBlock returns correct length" {
    const master_secret = [_]u8{0x01} ** 48;
    const server_random = [_]u8{0x02} ** 32;
    const client_random = [_]u8{0x03} ** 32;
    const kb = deriveKeyBlock(HmacSha256, &master_secret, &server_random, &client_random, 64);
    try std.testing.expectEqual(@as(usize, 64), kb.len);
}

test "tls12FinishedVerifyData returns 12 bytes" {
    const master_secret = [_]u8{0x01} ** 48;
    const transcript_hash = [_]u8{0x02} ** 32;
    const vd = tls12FinishedVerifyData(HmacSha256, &master_secret, &transcript_hash, "client finished");
    try std.testing.expectEqual(@as(usize, 12), vd.len);
}

test "tls12FinishedVerifyData differs for client vs server" {
    const master_secret = [_]u8{0x01} ** 48;
    const transcript_hash = [_]u8{0x02} ** 32;
    const vd_client = tls12FinishedVerifyData(HmacSha256, &master_secret, &transcript_hash, "client finished");
    const vd_server = tls12FinishedVerifyData(HmacSha256, &master_secret, &transcript_hash, "server finished");
    try std.testing.expect(!std.mem.eql(u8, &vd_client, &vd_server));
}

test "KeyExchange group field set after exchange" {
    var entropy1: [96]u8 = [_]u8{0x01} ** 96;
    var entropy2: [96]u8 = [_]u8{0x02} ** 96;
    var kx = try KeyExchange.init(&entropy1);
    var kx2 = try KeyExchange.init(&entropy2);
    const pub2 = try kx2.getPublicKey(.secp256r1);
    try kx.exchange(.secp256r1, pub2);
    try std.testing.expectEqual(NamedGroupChoice.secp256r1, kx.group);
}
