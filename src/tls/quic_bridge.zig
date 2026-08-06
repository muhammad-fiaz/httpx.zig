//! QUIC TLS 1.3 Key Schedule & CRYPTO Frame Bridge (RFC 9001)
//!
//! Exposes TLS 1.3 handshake message bytes and derived QUIC packet
//! protection keys without invoking the TCP TLS record layer.
//!
//! QUIC uses TLS 1.3 exclusively (RFC 9001 Section4.1), with the following
//! key differences from TCP TLS:
//!
//! - No TCP record layer  --  TLS messages are carried in CRYPTO frames
//! - No ChangeCipherSpec  --  encryption starts immediately
//! - QUIC uses its own packet protection with header protection keys
//! - Key derivation uses HKDF-Expand-Label with QUIC-specific labels

const std = @import("std");
const crypto = std.crypto;
const tls = std.crypto.tls;
const mem = std.mem;

const key_schedule = @import("key_schedule.zig");
const handshake = @import("handshake.zig");
const crypto_utils = @import("crypto_utils.zig");

const tlsRandom = crypto_utils.tlsRandom;

// QUIC TLS 1.3 handshake state

pub const QuicTlsState = enum {
    /// Initial state  --  no keys derived yet.
    initial,
    /// Client/Server Hello sent/received.
    handshake_started,
    /// Handshake traffic keys are available.
    handshake_keys_ready,
    /// Application traffic keys are available.
    application_keys_ready,
    /// Connection is established.
    connected,
};

// QUIC packet protection keys

pub const QuicPacketKeys = struct {
    /// AEAD encryption key.
    key: [32]u8,
    /// Initialization vector.
    iv: [12]u8,
    /// Header protection key.
    hp: [32]u8,
};

pub const QuicTrafficKeys = struct {
    /// Client-to-server keys.
    client: QuicPacketKeys,
    /// Server-to-client keys.
    server: QuicPacketKeys,
};

// QUIC-TLS bridge

pub const QuicCryptoBridge = struct {
    state: QuicTlsState = .initial,

    /// TLS 1.3 key schedule (SHA-256 for most cipher suites).
    ks: key_schedule.KeyScheduleSha256 = .{},

    /// Handshake traffic keys (available after ServerHello).
    handshake_keys: ?QuicTrafficKeys = null,

    /// Application traffic keys (available after Finished).
    app_keys: ?QuicTrafficKeys = null,

    /// Collected CRYPTO frame data for the handshake.
    crypto_in: std.ArrayList(u8),
    crypto_out: std.ArrayList(u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QuicCryptoBridge {
        return .{
            .crypto_in = std.ArrayList(u8).init(allocator),
            .crypto_out = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicCryptoBridge) void {
        self.crypto_in.deinit();
        self.crypto_out.deinit();
    }

    /// Process incoming CRYPTO frame data.
    pub fn processCryptoData(self: *QuicCryptoBridge, data: []const u8) !void {
        try self.crypto_in.appendSlice(data);
    }

    /// Get the next outgoing CRYPTO frame data to send.
    pub fn getNextCryptoData(self: *QuicCryptoBridge) ?[]const u8 {
        if (self.crypto_out.items.len == 0) return null;
        return self.crypto_out.items;
    }

    /// Derive QUIC packet protection keys from a traffic secret.
    /// Uses HKDF-Expand-Label with QUIC-specific labels (RFC 9001 Section5.1).
    pub fn deriveQuicKeys(self: *const QuicCryptoBridge, traffic_secret: []const u8) QuicTrafficKeys {
        const Hmac = crypto.auth.hmac.Hmac(crypto.hash.sha2.Sha256);
        const Hkdf = crypto.kdf.hkdf.Hkdf(Hmac);

        var client_secret: [32]u8 = undefined;
        var server_secret: [32]u8 = undefined;
        @memcpy(&client_secret, traffic_secret[0..32]);
        @memcpy(&server_secret, traffic_secret[0..32]);

        return .{
            .client = self.derivePacketKeys(Hkdf, &client_secret),
            .server = self.derivePacketKeys(Hkdf, &server_secret),
        };
    }

    fn derivePacketKeys(self: *const QuicCryptoBridge, Hkdf: type, secret: []const u8) QuicPacketKeys {
        _ = self;
        return .{
            .key = tls.hkdfExpandLabel(Hkdf, secret.*, "quic key", "", 32),
            .iv = tls.hkdfExpandLabel(Hkdf, secret.*, "quic iv", "", 12),
            .hp = tls.hkdfExpandLabel(Hkdf, secret.*, "quic hp", "", 32),
        };
    }

    /// Get the handshake traffic keys (if available).
    pub fn getHandshakeKeys(self: *const QuicCryptoBridge) ?QuicTrafficKeys {
        return self.handshake_keys;
    }

    /// Get the application traffic keys (if available).
    pub fn getAppKeys(self: *const QuicCryptoBridge) ?QuicTrafficKeys {
        return self.app_keys;
    }

    /// Check if the handshake is complete.
    pub fn isComplete(self: *const QuicCryptoBridge) bool {
        return self.state == .connected;
    }

    /// Get the current TLS state.
    pub fn getState(self: *const QuicCryptoBridge) QuicTlsState {
        return self.state;
    }
};

// QUIC Initial packet protection (RFC 9001 Section5.3)

/// Derive QUIC Initial packet keys from the Connection ID.
/// These are used before any TLS handshake messages are exchanged.
pub fn deriveInitialKeys(connection_id: []const u8) QuicPacketKeys {
    const Hmac = crypto.auth.hmac.Hmac(crypto.hash.sha2.Sha256);
    const Hkdf = crypto.kdf.hkdf.Hkdf(Hmac);

    const salt = [_]u8{
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
        0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
        0x2b, 0xb7, 0x3c, 0xe4, 0x39, 0x68, 0x06, 0x30,
        0x49, 0x37, 0x3c, 0x49, 0x0d, 0x84, 0x5d, 0xa2,
    };

    const initial_secret = Hkdf.extract(&salt, connection_id);

    const hs_secret = tls.hkdfExpandLabel(Hkdf, initial_secret, "client in", "", 32);

    return .{
        .key = tls.hkdfExpandLabel(Hkdf, hs_secret, "quic key", "", 16),
        .iv = tls.hkdfExpandLabel(Hkdf, hs_secret, "quic iv", "", 12),
        .hp = tls.hkdfExpandLabel(Hkdf, hs_secret, "quic hp", "", 16),
    };
}

// Tests

test "QuicCryptoBridge init" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expectEqual(QuicTlsState.initial, bridge.getState());
    try std.testing.expect(!bridge.isComplete());
}

test "deriveInitialKeys produces non-zero keys" {
    const cid = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const keys = deriveInitialKeys(&cid);
    var all_zero = true;
    for (keys.key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "deriveQuicKeys produces distinct client/server keys" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();

    var secret: [32]u8 = undefined;
    tlsRandom(&secret);
    const keys = bridge.deriveQuicKeys(&secret);

    try std.testing.expect(!std.mem.eql(u8, &keys.client.key, &keys.server.key));
    try std.testing.expect(!std.mem.eql(u8, &keys.client.iv, &keys.server.iv));
    try std.testing.expect(!std.mem.eql(u8, &keys.client.hp, &keys.server.hp));
}

test "QuicCryptoBridge processCryptoData appends data" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();

    const data = "hello crypto";
    try bridge.processCryptoData(data);
    try std.testing.expectEqual(@as(usize, data.len), bridge.crypto_in.items.len);
}

test "QuicCryptoBridge getNextCryptoData returns null when empty" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();

    try std.testing.expect(bridge.getNextCryptoData() == null);
}

test "deriveInitialKeys different connection IDs produce different keys" {
    const cid1 = [_]u8{0x01} ** 8;
    const cid2 = [_]u8{0x02} ** 8;
    const keys1 = deriveInitialKeys(&cid1);
    const keys2 = deriveInitialKeys(&cid2);
    try std.testing.expect(!std.mem.eql(u8, &keys1.key, &keys2.key));
}

test "deriveInitialKeys produces 16-byte key" {
    const cid = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const keys = deriveInitialKeys(&cid);
    try std.testing.expectEqual(@as(usize, 16), keys.key.len);
    try std.testing.expectEqual(@as(usize, 12), keys.iv.len);
    try std.testing.expectEqual(@as(usize, 16), keys.hp.len);
}

test "QuicCryptoBridge getHandshakeKeys returns null initially" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expect(bridge.getHandshakeKeys() == null);
}

test "QuicCryptoBridge getAppKeys returns null initially" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expect(bridge.getAppKeys() == null);
}

test "QuicCryptoBridge state transitions" {
    var bridge = QuicCryptoBridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expectEqual(QuicTlsState.initial, bridge.getState());
    bridge.state = .handshake_started;
    try std.testing.expectEqual(QuicTlsState.handshake_started, bridge.getState());
    bridge.state = .connected;
    try std.testing.expect(bridge.isComplete());
}
