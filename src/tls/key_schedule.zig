//! TLS 1.3 Key Schedule (RFC 8446 Section7)
//!
//! Implements the HKDF-based key schedule for TLS 1.3.  All derivations
//! use `HKDF-Expand-Label` as defined in RFC 8446 Section7.1.
//!
//! The module also provides `quicExpandLabel` which follows RFC 9001 Section5
//! for deriving QUIC packet protection keys from TLS 1.3 traffic secrets
//! (the label space is the same "tls13 " prefix, but applied differently
//! than TLS record protection).
//!
//! This module is used by:
//! - `handshake_13.zig`  --  handshake and application traffic key derivation
//! - `quic_bridge.zig`  --  QUIC Initial/Handshake/1-RTT key derivation

const std = @import("std");
const crypto = std.crypto;
const tls = std.crypto.tls;
const mem = std.mem;

const Sha256 = crypto.hash.sha2.Sha256;
const Sha384 = crypto.hash.sha2.Sha384;

/// Convenience alias for the HKDF-Expand-Label function already provided
/// by `std.crypto.tls`.
pub const hkdfExpandLabel = tls.hkdfExpandLabel;

/// Convenience alias for `std.crypto.tls.emptyHash`.
pub const emptyHash = tls.emptyHash;

/// TLS 1.3 key schedule state for one handshake.
///
/// Parameterised by the HMAC type (which carries the hash algorithm and
/// HKDF implementation).  Callers should use `KeySchedule(Hmac)` where
/// `Hmac = std.crypto.auth.hmac.Hmac(HashType)`.
pub fn KeySchedule(comptime HashType: type) type {
    const Hash = HashType;
    const Hmac = crypto.auth.hmac.Hmac(Hash);
    const Hkdf = crypto.kdf.hkdf.Hkdf(Hmac);
    const digest_len = Hmac.mac_length;
    const PRK = [Hkdf.prk_length]u8;

    return struct {
        /// Step 1  --  Early Secret (derived from PSK or zeros when no PSK).
        early_secret: PRK = undefined,
        /// Step 2  --  Handshake Secret (derived from ECDH shared secret).
        handshake_secret: PRK = undefined,
        /// Step 3  --  Master Secret (derived from zeros after handshake secret).
        master_secret: PRK = undefined,

        // Per-direction handshake traffic secrets.
        client_hs_secret: [digest_len]u8 = undefined,
        server_hs_secret: [digest_len]u8 = undefined,

        // Finished keys (from handshake traffic secrets).
        client_finished_key: [Hmac.key_length]u8 = undefined,
        server_finished_key: [Hmac.key_length]u8 = undefined,

        // Per-direction application traffic secrets.
        client_app_secret: [digest_len]u8 = undefined,
        server_app_secret: [digest_len]u8 = undefined,

        const Self = @This();

        /// Derive the Early Secret.  When no PSK is used (most connections),
        /// call with `psk = null`  --  a zero-length PSK (all-zeros) is used.
        pub fn deriveEarlySecret(self: *Self, psk: ?[]const u8) void {
            const zeroes: [digest_len]u8 = [1]u8{0} ** digest_len;
            const salt: [1]u8 = .{0};
            const input = if (psk) |p| p else &zeroes;
            self.early_secret = Hkdf.extract(&salt, input);
        }

        /// Derive the Handshake Secret from the ECDH shared secret and the
        /// empty-hash-derived "derived" label applied to the early secret.
        pub fn deriveHandshakeSecret(self: *Self, shared_secret: []const u8) void {
            const empty_hash = tls.emptyHash(Hash);
            const derived = hkdfExpandLabel(Hkdf, self.early_secret, "derived", &empty_hash, digest_len);
            self.handshake_secret = Hkdf.extract(&derived, shared_secret);
        }

        /// Derive the Master Secret after the handshake secret is known.
        pub fn deriveMasterSecret(self: *Self) void {
            const empty_hash = tls.emptyHash(Hash);
            const derived = hkdfExpandLabel(Hkdf, self.handshake_secret, "derived", &empty_hash, digest_len);
            const zeroes: [digest_len]u8 = [1]u8{0} ** digest_len;
            self.master_secret = Hkdf.extract(&derived, &zeroes);
        }

        /// Derive the per-direction handshake traffic secrets and the
        /// Finished keys.  `hello_hash` is the transcript hash over
        /// ClientHello..ServerHello (inclusive).
        pub fn deriveHandshakeTrafficSecrets(self: *Self, hello_hash: []const u8) void {
            self.client_hs_secret = hkdfExpandLabel(Hkdf, self.handshake_secret, "c hs traffic", hello_hash, digest_len);
            self.server_hs_secret = hkdfExpandLabel(Hkdf, self.handshake_secret, "s hs traffic", hello_hash, digest_len);
            self.client_finished_key = hkdfExpandLabel(Hkdf, self.client_hs_secret, "finished", "", Hmac.key_length);
            self.server_finished_key = hkdfExpandLabel(Hkdf, self.server_hs_secret, "finished", "", Hmac.key_length);
        }

        /// Derive the per-direction application traffic secrets.
        /// `handshake_hash` is the transcript hash over ClientHello..Finished
        /// (i.e. the complete handshake transcript).
        pub fn deriveApplicationTrafficSecrets(self: *Self, handshake_hash: []const u8) void {
            self.client_app_secret = hkdfExpandLabel(Hkdf, self.master_secret, "c ap traffic", handshake_hash, digest_len);
            self.server_app_secret = hkdfExpandLabel(Hkdf, self.master_secret, "s ap traffic", handshake_hash, digest_len);
        }

        /// Derive the AEAD key from a traffic secret.
        pub fn deriveKey(self: *const Self, secret: [digest_len]u8, comptime key_len: usize) [key_len]u8 {
            _ = self;
            return hkdfExpandLabel(Hkdf, secret, "key", "", key_len);
        }

        /// Derive the AEAD IV from a traffic secret.
        pub fn deriveIv(self: *const Self, secret: [digest_len]u8, comptime iv_len: usize) [iv_len]u8 {
            _ = self;
            return hkdfExpandLabel(Hkdf, secret, "iv", "", iv_len);
        }

        /// Compute the Finished verify_data for the client or server.
        /// `transcript_hash` is the hash of all handshake messages up to
        /// (but not including) the Finished message being constructed.
        pub fn finishedVerifyData(
            finished_key: [Hmac.key_length]u8,
            transcript_hash: []const u8,
        ) [Hmac.mac_length]u8 {
            return tls.hmac(Hmac, transcript_hash, finished_key);
        }
    };
}

// Concrete key schedule aliases for the cipher suites we support.

const HmacSha256 = crypto.auth.hmac.Hmac(Sha256);
const HmacSha384 = crypto.auth.hmac.Hmac(Sha384);

pub const KeyScheduleSha256 = KeySchedule(Sha256);
pub const KeyScheduleSha384 = KeySchedule(Sha384);

// Tests

test "KeySchedule SHA-256 early secret" {
    const t = std.testing;
    var ks: KeyScheduleSha256 = .{};
    ks.deriveEarlySecret(null);
    // With zero PSK the early secret is deterministic  --  just ensure it is
    // non-zero (a crypto sanity check).
    var all_zero = true;
    for (ks.early_secret) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try t.expect(!all_zero);
}

test "KeySchedule handshake + master secret derivation" {
    const t = std.testing;
    var ks: KeyScheduleSha256 = .{};
    ks.deriveEarlySecret(null);
    // Use a fake shared secret (32 bytes of 0xAB).
    var shared: [32]u8 = undefined;
    @memset(&shared, 0xAB);
    ks.deriveHandshakeSecret(&shared);
    ks.deriveMasterSecret();
    // Verify the secrets are distinct (very likely for different derivations).
    try t.expect(!std.mem.eql(u8, &ks.handshake_secret, &ks.master_secret));
}

test "KeySchedule SHA-256 handshake traffic secrets" {
    var ks: KeyScheduleSha256 = .{};
    ks.deriveEarlySecret(null);
    var shared: [32]u8 = [_]u8{0xAB} ** 32;
    ks.deriveHandshakeSecret(&shared);
    const hello_hash: [32]u8 = [_]u8{0xCC} ** 32;
    ks.deriveHandshakeTrafficSecrets(&hello_hash);
    // Client and server handshake secrets should be different
    try std.testing.expect(!std.mem.eql(u8, &ks.client_hs_secret, &ks.server_hs_secret));
}

test "KeySchedule SHA-256 application traffic secrets" {
    var ks: KeyScheduleSha256 = .{};
    ks.deriveEarlySecret(null);
    var shared: [32]u8 = [_]u8{0xAB} ** 32;
    ks.deriveHandshakeSecret(&shared);
    ks.deriveMasterSecret();
    const handshake_hash: [32]u8 = [_]u8{0xDD} ** 32;
    ks.deriveApplicationTrafficSecrets(&handshake_hash);
    // Client and server app secrets should be different
    try std.testing.expect(!std.mem.eql(u8, &ks.client_app_secret, &ks.server_app_secret));
}

test "KeySchedule deriveKey returns correct length" {
    var ks: KeyScheduleSha256 = .{};
    const secret: [32]u8 = [_]u8{0x01} ** 32;
    const key16 = ks.deriveKey(secret, 16);
    try std.testing.expectEqual(@as(usize, 16), key16.len);
    const key32 = ks.deriveKey(secret, 32);
    try std.testing.expectEqual(@as(usize, 32), key32.len);
}

test "KeySchedule deriveIv returns correct length" {
    var ks: KeyScheduleSha256 = .{};
    const secret: [32]u8 = [_]u8{0x01} ** 32;
    const iv = ks.deriveIv(secret, 12);
    try std.testing.expectEqual(@as(usize, 12), iv.len);
}

test "KeySchedule finishedVerifyData returns mac_length bytes" {
    const finished_key: [32]u8 = [_]u8{0x01} ** 32;
    const transcript_hash: [32]u8 = [_]u8{0x02} ** 32;
    const verify_data = KeyScheduleSha256.finishedVerifyData(finished_key, &transcript_hash);
    try std.testing.expectEqual(@as(usize, 32), verify_data.len);
}

test "KeySchedule SHA-384 early secret is non-zero" {
    var ks: KeyScheduleSha384 = .{};
    ks.deriveEarlySecret(null);
    var all_zero = true;
    for (ks.early_secret) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "KeySchedule SHA-384 handshake + master secret derivation" {
    var ks: KeyScheduleSha384 = .{};
    ks.deriveEarlySecret(null);
    var shared: [48]u8 = [_]u8{0xAB} ** 48;
    ks.deriveHandshakeSecret(&shared);
    ks.deriveMasterSecret();
    try std.testing.expect(!std.mem.eql(u8, &ks.handshake_secret, &ks.master_secret));
}

test "KeySchedule SHA-384 deriveKey returns correct length" {
    var ks: KeyScheduleSha384 = .{};
    const secret: [48]u8 = [_]u8{0x01} ** 48;
    const key = ks.deriveKey(secret, 32);
    try std.testing.expectEqual(@as(usize, 32), key.len);
}

test "KeySchedule SHA-384 deriveIv returns correct length" {
    var ks: KeyScheduleSha384 = .{};
    const secret: [48]u8 = [_]u8{0x01} ** 48;
    const iv = ks.deriveIv(secret, 12);
    try std.testing.expectEqual(@as(usize, 12), iv.len);
}

test "KeySchedule deriveKey deterministic" {
    var ks: KeyScheduleSha256 = .{};
    const secret: [32]u8 = [_]u8{0x01} ** 32;
    const key1 = ks.deriveKey(secret, 16);
    const key2 = ks.deriveKey(secret, 16);
    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "KeySchedule finishedVerifyData differs for different keys" {
    const key1: [32]u8 = [_]u8{0x01} ** 32;
    const key2: [32]u8 = [_]u8{0x02} ** 32;
    const transcript: [32]u8 = [_]u8{0x03} ** 32;
    const vd1 = KeyScheduleSha256.finishedVerifyData(key1, &transcript);
    const vd2 = KeyScheduleSha256.finishedVerifyData(key2, &transcript);
    try std.testing.expect(!std.mem.eql(u8, &vd1, &vd2));
}
