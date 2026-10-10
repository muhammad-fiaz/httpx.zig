//! QUIC-TLS 1.3 key schedule (RFC 8446 Section 7.1 as profiled by RFC 9001 Section 7).
//!
//! Implements the secret chain a full handshake driver needs:
//!   sharedSecret (ECDHE) -> handshake secrets -> application secrets
//!   -> update via "quic ku" / resumption via derived-secret + "resumption"
//! All HKDF-Expand-Label traffic goes through protocols/quic/crypto.zig so
//! labels live in ONE place. This module is driver-ready: a TLS engine only
//! supplies the ECDHE shared secret + transport parameters transcript hash.
//! Integration proof: the TLS-in-QUIC loopback test in
//! protocols/quic/connection.zig drives the TLS engine through CRYPTO
//! frames and installs these keys on live packet-number spaces.

const std = @import("std");
const qcrypto = @import("../quic/crypto.zig");
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

pub const Error = error{
    OutOfMemory,
};

/// One encryption level's directional material.
pub const LevelKeys = struct {
    txSecret: [32]u8,
    rxSecret: [32]u8,
    tx: qcrypto.ProtectionKeys,
    rx: qcrypto.ProtectionKeys,
};

fn level(txSecret: [32]u8, rxSecret: [32]u8) LevelKeys {
    return .{
        .txSecret = txSecret,
        .rxSecret = rxSecret,
        .tx = qcrypto.deriveProtectionKeys(txSecret),
        .rx = qcrypto.deriveProtectionKeys(rxSecret),
    };
}

fn emptyHash() [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    return h.finalResult();
}

/// Derives Early Secret from a PSK (RFC 8446 Section 7.1).
pub fn earlySecret(psk: [32]u8) [32]u8 {
    const zero: [32]u8 = @splat(0);
    return HkdfSha256.extract(&zero, &psk);
}

/// Derives client_early_traffic_secret from Early Secret and ClientHello hash.
pub fn clientEarlyTrafficSecret(earlySec: [32]u8, chHash: [32]u8) [32]u8 {
    return qcrypto.deriveSecretWithContext(earlySec, "c e traffic", &chHash);
}

/// Derives 0-RTT keys from a PSK and ClientHello hash (RFC 9001 Section 5.2).
pub fn earlyKeys(psk: [32]u8, chHash: [32]u8) struct { earlySec: [32]u8, cEarlySecret: [32]u8, keys: qcrypto.ProtectionKeys } {
    const es = earlySecret(psk);
    const cets = clientEarlyTrafficSecret(es, chHash);
    return .{
        .earlySec = es,
        .cEarlySecret = cets,
        .keys = qcrypto.deriveProtectionKeys(cets),
    };
}

/// Derives 0-RTT keys for a specific cipher from a PSK and ClientHello hash.
pub fn earlyKeysForCipher(psk: [32]u8, chHash: [32]u8, cipher: qcrypto.Cipher) struct { earlySec: [32]u8, cEarlySecret: [32]u8, keys: qcrypto.ProtectionKeys } {
    const es = earlySecret(psk);
    const cets = clientEarlyTrafficSecret(es, chHash);
    return .{
        .earlySec = es,
        .cEarlySecret = cets,
        .keys = qcrypto.deriveProtectionKeysForCipher(cets, cipher),
    };
}

pub const HandshakeKeysResult = struct { hsSecret: [32]u8, keys: LevelKeys };

/// Derives Handshake-level keys given an established Early Secret (from PSK or initial 0),
/// ECDHE shared secret, and CH..SH transcript hash.
pub fn handshakeKeysWithEarly(earlySec: [32]u8, sharedSecret: [32]u8, chShHash: [32]u8) HandshakeKeysResult {
    const eh = emptyHash();
    const derived = qcrypto.deriveSecretWithContext(earlySec, "derived", &eh);
    const hs = HkdfSha256.extract(&derived, &sharedSecret);
    const cHs = qcrypto.deriveSecretWithContext(hs, "c hs traffic", &chShHash);
    const sHs = qcrypto.deriveSecretWithContext(hs, "s hs traffic", &chShHash);
    return .{ .hsSecret = hs, .keys = level(cHs, sHs) };
}

/// Derives Handshake-level keys from the ECDHE shared secret and the
/// CH..SH transcript hash (RFC 8446 Section 7.1 as profiled by RFC 9001
/// Section 7.2): early=Extract(0,0); derived=Derive(early,"derived","").
/// hs=Extract(derived,shared); c/s hs traffic=Derive(hs,...,hash).
pub fn handshakeKeys(sharedSecret: [32]u8, chShHash: [32]u8) HandshakeKeysResult {
    const zero: [32]u8 = @splat(0);
    const early = earlySecret(zero);
    return handshakeKeysWithEarly(early, sharedSecret, chShHash);
}

/// Derives Application (1-RTT) keys from the handshake secret and the
/// CH..SF transcript hash: derived=Derive(hs,"derived","").
/// master=Extract(derived,0); c/s ap traffic=Derive(master,...,hash).
pub fn applicationKeys(hsSecret: [32]u8, chSfHash: [32]u8) struct { apSecret: [32]u8, keys: LevelKeys } {
    const eh = emptyHash();
    const derived = qcrypto.deriveSecretWithContext(hsSecret, "derived", &eh);
    const zero: [32]u8 = @splat(0);
    const master = HkdfSha256.extract(&derived, &zero);
    const cAp = qcrypto.deriveSecretWithContext(master, "c ap traffic", &chSfHash);
    const sAp = qcrypto.deriveSecretWithContext(master, "s ap traffic", &chSfHash);
    return .{ .apSecret = master, .keys = level(cAp, sAp) };
}

/// RFC 9114/9001 key update ("quic ku") for one direction's secret.
pub fn updateSecret(current: [32]u8) [32]u8 {
    return qcrypto.deriveSecret(current, "quic ku");
}

/// Resumption master secret path (post-handshake, RFC 8446 Section 7.5):
/// rms = Derive-Secret(apSecret, "resumption", finalTranscriptHash).
pub fn resumptionMaster(apSecret: [32]u8, finalTranscriptHash: [32]u8) [32]u8 {
    return qcrypto.deriveSecretWithContext(apSecret, "resumption", &finalTranscriptHash);
}

// Tests

test "handshake -> application chain is deterministic and symmetric" {
    var shared: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    prng.random().bytes(&shared);
    const h1: [32]u8 = @splat(0x11);
    const h2: [32]u8 = @splat(0x22);

    const hs = handshakeKeys(shared, h1);
    // Client/server secrets differ but derive from one chain point.
    try std.testing.expect(!std.mem.eql(u8, &hs.keys.txSecret, &hs.keys.rxSecret));

    const ap = applicationKeys(hs.hsSecret, h2);
    try std.testing.expect(!std.mem.eql(u8, &ap.keys.txSecret, &hs.keys.txSecret));

    // Same input twice => same output (HKDF determinism).
    const hs2 = handshakeKeys(shared, h1);
    try std.testing.expectEqualSlices(u8, &hs.keys.txSecret, &hs2.keys.txSecret);

    // Transcript binding: different hash => different secrets.
    const hs3 = handshakeKeys(shared, h2);
    try std.testing.expect(!std.mem.eql(u8, &hs.keys.txSecret, &hs3.keys.txSecret));

    // Protection keys match what installKeys would consume.
    const direct = qcrypto.deriveProtectionKeys(hs.keys.txSecret);
    try std.testing.expectEqualSlices(u8, &direct.key, &hs.keys.tx.key);
}

test "key update chains forward without reusing old secrets" {
    var s: [32]u8 = @splat(7);
    const k1 = updateSecret(s);
    const k2 = updateSecret(k1);
    try std.testing.expect(!std.mem.eql(u8, &s, &k1));
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "0-RTT earlyKeys derives keys and chains into handshake and application keys" {
    const psk: [32]u8 = @splat(0xAA);
    const chHash: [32]u8 = @splat(0x12);
    const early = earlyKeys(psk, chHash);

    // Early secret and client early traffic secret are not all-zero and distinct
    const zero: [32]u8 = @splat(0);
    try std.testing.expect(!std.mem.eql(u8, &early.earlySec, &zero));
    try std.testing.expect(!std.mem.eql(u8, &early.cEarlySecret, &zero));
    try std.testing.expect(!std.mem.eql(u8, &early.earlySec, &early.cEarlySecret));

    // 0-RTT protection keys are populated
    try std.testing.expectEqual(@as(usize, 16), early.keys.keyLen);
    try std.testing.expectEqual(@as(usize, 16), early.keys.hpLen);

    // Chaining: earlySecret -> handshakeKeysWithEarly -> applicationKeys
    const shared: [32]u8 = @splat(0xBB);
    const chShHash: [32]u8 = @splat(0x34);
    const hs = handshakeKeysWithEarly(early.earlySec, shared, chShHash);
    try std.testing.expect(!std.mem.eql(u8, &hs.hsSecret, &early.earlySec));

    const chSfHash: [32]u8 = @splat(0x56);
    const ap = applicationKeys(hs.hsSecret, chSfHash);
    try std.testing.expect(!std.mem.eql(u8, &ap.apSecret, &hs.hsSecret));
}
