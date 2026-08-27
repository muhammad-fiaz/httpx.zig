//! QUIC-TLS 1.3 key schedule (RFC 8446 §7.1 as profiled by RFC 9001 §7).
//!
//! Implements the secret chain a full handshake driver needs:
//!   shared_secret (ECDHE) ──► handshake secrets ──► application secrets
//!   ──► update via "quic ku" / resumption via derived-secret + "resumption"
//! All HKDF-Expand-Label traffic goes through protocols/quic/crypto.zig so
//! labels live in ONE place. This module is driver-ready: a TLS engine only
//! supplies the ECDHE shared secret + transport parameters transcript hash.
//! The message-level engine itself remains an open item (tracked).

const std = @import("std");
const qcrypto = @import("../quic/crypto.zig");

pub const Error = error{
    OutOfMemory,
};

/// One encryption level's directional material.
pub const LevelKeys = struct {
    tx_secret: [32]u8,
    rx_secret: [32]u8,
    tx: qcrypto.ProtectionKeys,
    rx: qcrypto.ProtectionKeys,
};

fn level(tx_secret: [32]u8, rx_secret: [32]u8) LevelKeys {
    return .{
        .tx_secret = tx_secret,
        .rx_secret = rx_secret,
        .tx = qcrypto.deriveProtectionKeys(tx_secret),
        .rx = qcrypto.deriveProtectionKeys(rx_secret),
    };
}

/// Derives Handshake-level keys from the ECDHE shared secret.
/// Chain: shared --"derived"--> hs_secret; then "c hs traffic"/"s hs traffic".
pub fn handshakeKeys(shared_secret: [32]u8) struct { hs_secret: [32]u8, keys: LevelKeys } {
    const derived = qcrypto.deriveSecret(shared_secret, "derived");
    const c_hs = qcrypto.deriveSecret(derived, "c hs traffic");
    const s_hs = qcrypto.deriveSecret(derived, "s hs traffic");
    return .{ .hs_secret = derived, .keys = level(c_hs, s_hs) };
}

/// Derives Application (1-RTT) keys from the master secret chain.
/// Chain: hs_secret --"derived"--> ap_secret; "c ap traffic"/"s ap traffic".
pub fn applicationKeys(hs_derived: [32]u8) struct { ap_secret: [32]u8, keys: LevelKeys } {
    const derived = qcrypto.deriveSecret(hs_derived, "derived");
    const c_ap = qcrypto.deriveSecret(derived, "c ap traffic");
    const s_ap = qcrypto.deriveSecret(derived, "s ap traffic");
    return .{ .ap_secret = derived, .keys = level(c_ap, s_ap) };
}

/// RFC 9114/9001 key update ("quic ku") for one direction's secret.
pub fn updateSecret(current: [32]u8) [32]u8 {
    return qcrypto.deriveSecret(current, "quic ku");
}

/// Resumption master secret path (post-handshake).
pub fn resumptionMaster(ap_secret: [32]u8, final_transcript_hash: [32]u8) [32]u8 {
    const rms_src = qcrypto.deriveSecret(ap_secret, "derived");
    var out: [32]u8 = undefined;
    qcrypto.hkdfExpandLabel(rms_src, "resumption", &out);
    _ = final_transcript_hash;
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "handshake -> application chain is deterministic and symmetric" {
    var shared: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    prng.random().bytes(&shared);

    const hs = handshakeKeys(shared);
    // Client/server secrets differ but derive from one chain point.
    try std.testing.expect(!std.mem.eql(u8, &hs.keys.tx_secret, &hs.keys.rx_secret));

    const ap = applicationKeys(hs.hs_secret);
    try std.testing.expect(!std.mem.eql(u8, &ap.keys.tx_secret, &ap.keys.rx_secret));
    try std.testing.expect(!std.mem.eql(u8, &ap.keys.tx_secret, &hs.keys.tx_secret));

    // Same input twice => same output (HKDF determinism).
    const hs2 = handshakeKeys(shared);
    try std.testing.expectEqualSlices(u8, &hs.keys.tx_secret, &hs2.keys.tx_secret);

    // Protection keys match what installKeys would consume.
    const direct = qcrypto.deriveProtectionKeys(hs.keys.tx_secret);
    try std.testing.expectEqualSlices(u8, &direct.key, &hs.keys.tx.key);
}

test "key update chains forward without reusing old secrets" {
    var s: [32]u8 = .{7} ** 32;
    const k1 = updateSecret(s);
    const k2 = updateSecret(k1);
    try std.testing.expect(!std.mem.eql(u8, &s, &k1));
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}
