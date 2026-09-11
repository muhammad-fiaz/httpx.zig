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

/// Derives Handshake-level keys from the ECDHE shared secret and the
/// CH..SH transcript hash (RFC 8446 Section 7.1 as profiled by RFC 9001
/// Section 7.2): early=Extract(0,0); derived=Derive(early,"derived","").
/// hs=Extract(derived,shared); c/s hs traffic=Derive(hs,...,hash).
pub fn handshakeKeys(sharedSecret: [32]u8, chShHash: [32]u8) struct { hsSecret: [32]u8, keys: LevelKeys } {
    const zero: [32]u8 = .{0} ** 32;
    const early = HkdfSha256.extract(&zero, &zero);
    const eh = emptyHash();
    const derived = qcrypto.deriveSecretWithContext(early, "derived", &eh);
    const hs = HkdfSha256.extract(&derived, &sharedSecret);
    const c_hs = qcrypto.deriveSecretWithContext(hs, "c hs traffic", &chShHash);
    const s_hs = qcrypto.deriveSecretWithContext(hs, "s hs traffic", &chShHash);
    return .{ .hsSecret = hs, .keys = level(c_hs, s_hs) };
}

/// Derives Application (1-RTT) keys from the handshake secret and the
/// CH..SF transcript hash: derived=Derive(hs,"derived","").
/// master=Extract(derived,0); c/s ap traffic=Derive(master,...,hash).
pub fn applicationKeys(hsSecret: [32]u8, chSfHash: [32]u8) struct { apSecret: [32]u8, keys: LevelKeys } {
    const eh = emptyHash();
    const derived = qcrypto.deriveSecretWithContext(hsSecret, "derived", &eh);
    const zero: [32]u8 = .{0} ** 32;
    const master = HkdfSha256.extract(&derived, &zero);
    const c_ap = qcrypto.deriveSecretWithContext(master, "c ap traffic", &chSfHash);
    const s_ap = qcrypto.deriveSecretWithContext(master, "s ap traffic", &chSfHash);
    return .{ .apSecret = master, .keys = level(c_ap, s_ap) };
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
    const h1: [32]u8 = .{0x11} ** 32;
    const h2: [32]u8 = .{0x22} ** 32;

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
    var s: [32]u8 = .{7} ** 32;
    const k1 = updateSecret(s);
    const k2 = updateSecret(k1);
    try std.testing.expect(!std.mem.eql(u8, &s, &k1));
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}
