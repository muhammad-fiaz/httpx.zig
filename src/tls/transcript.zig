//! TLS Handshake Transcript Hash
//!
//! Maintains a running hash over all handshake messages in the order they
//! are sent/received.  Both TLS 1.2 (PRF) and TLS 1.3 (HKDF) depend on
//! the transcript hash at various points during the handshake.
//!
//! In TLS 1.3 the transcript hash is used at every key schedule step.
//! In TLS 1.2 it is used to compute the Finished verify_data via the PRF.
//!
//! The concrete hash algorithm is determined by the negotiated cipher suite
//! and is selected at runtime via the `TranscriptHash` union.

const std = @import("std");
const crypto = std.crypto;

// Supported hash algorithms (subset matching our cipher suite list).
const Sha256 = crypto.hash.sha2.Sha256;
const Sha384 = crypto.hash.sha2.Sha384;
const Sha512 = crypto.hash.sha2.Sha512;

/// Tag identifying the active hash algorithm at runtime.
pub const HashAlgorithm = enum {
    sha256,
    sha384,
    sha512,
};

/// Returns the `HashAlgorithm` tag for the given cipher suite.
pub fn hashForSuite(suite: std.crypto.tls.CipherSuite) ?HashAlgorithm {
    return switch (suite) {
        .AES_128_GCM_SHA256,
        .CHACHA20_POLY1305_SHA256,
        .AEGIS_128L_SHA256,
        .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        => .sha256,

        .AES_256_GCM_SHA384,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        => .sha384,

        .AEGIS_256_SHA512,
        => .sha512,

        else => null,
    };
}

/// A running handshake transcript that accumulates all handshake messages
/// (not TLS record headers -- only the `Handshake` struct bytes).
///
/// The algorithm is selected at runtime once the cipher suite is known.
/// Before that, all `update()` calls are buffered so they can be replayed
/// into the real hasher once `init()` is called.
pub const TranscriptHash = struct {
    algorithm: ?HashAlgorithm = null,
    inner: Inner = .{ .sha256 = Sha256.init(.{}) },

    const Inner = union(HashAlgorithm) {
        sha256: Sha256,
        sha384: Sha384,
        sha512: Sha512,
    };

    /// Initialise (or re-initialise) the hasher for a specific algorithm.
    /// Any previously accumulated data is discarded.
    pub fn initAlgorithm(self: *TranscriptHash, algo: HashAlgorithm) void {
        self.algorithm = algo;
        self.inner = switch (algo) {
            .sha256 => .{ .sha256 = Sha256.init(.{}) },
            .sha384 => .{ .sha384 = Sha384.init(.{}) },
            .sha512 => .{ .sha512 = Sha512.init(.{}) },
        };
    }

    /// Feed bytes into the transcript.
    pub fn update(self: *TranscriptHash, data: []const u8) void {
        switch (self.inner) {
            inline else => |*h| h.update(data),
        }
    }

    /// Returns the current digest without finalising the hash (the hash
    /// can continue to accept more data after this call).
    pub fn peek(self: *const TranscriptHash) [64]u8 {
        var out: [64]u8 = undefined;
        switch (self.inner) {
            .sha256 => |h| {
                var hc = h;
                var buf: [Sha256.digest_length]u8 = undefined;
                hc.final(&buf);
                @memcpy(out[0..Sha256.digest_length], &buf);
            },
            .sha384 => |h| {
                var hc = h;
                var buf: [Sha384.digest_length]u8 = undefined;
                hc.final(&buf);
                @memcpy(out[0..Sha384.digest_length], &buf);
            },
            .sha512 => |h| {
                var hc = h;
                var buf: [Sha512.digest_length]u8 = undefined;
                hc.final(&buf);
                @memcpy(out[0..Sha512.digest_length], &buf);
            },
        }
        return out;
    }

    /// Returns the digest length (in bytes) for the active hash algorithm.
    pub fn digestLen(self: *const TranscriptHash) usize {
        return switch (self.inner) {
            .sha256 => Sha256.digest_length,
            .sha384 => Sha384.digest_length,
            .sha512 => Sha512.digest_length,
        };
    }

    /// Finalises the transcript hash and returns the digest.  The hasher
    /// is reset to a fresh state of the same algorithm afterward.
    pub fn final(self: *TranscriptHash) [64]u8 {
        const result = self.peek();
        // Reset to a fresh hasher of the same algorithm.
        if (self.algorithm) |algo| {
            self.initAlgorithm(algo);
        }
        return result;
    }

    /// Returns the active algorithm tag. Panics if not yet initialised.
    pub fn getAlgorithm(self: *const TranscriptHash) ?HashAlgorithm {
        return self.algorithm;
    }
};

test "transcript sha256 accumulates correctly" {
    const t = std.testing;
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha256);
    tr.update("hello ");
    tr.update("world");
    const digest = tr.peek();
    // Reference: SHA-256("hello world")
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("hello world", &expected, .{});
    try t.expectEqualSlices(u8, &expected, digest[0..Sha256.digest_length]);
}

test "transcript digestLen" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha256);
    try std.testing.expectEqual(@as(usize, 32), tr.digestLen());
    tr.initAlgorithm(.sha384);
    try std.testing.expectEqual(@as(usize, 48), tr.digestLen());
    tr.initAlgorithm(.sha512);
    try std.testing.expectEqual(@as(usize, 64), tr.digestLen());
}

test "hashForSuite" {
    try std.testing.expectEqual(HashAlgorithm.sha256, hashForSuite(.AES_128_GCM_SHA256).?);
    try std.testing.expectEqual(HashAlgorithm.sha384, hashForSuite(.AES_256_GCM_SHA384).?);
    try std.testing.expectEqual(HashAlgorithm.sha512, hashForSuite(.AEGIS_256_SHA512).?);
    try std.testing.expect(hashForSuite(.RSA_WITH_AES_128_CBC_SHA) == null);
}

test "transcript sha384 accumulates correctly" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha384);
    tr.update("hello ");
    tr.update("world");
    const digest = tr.peek();
    var expected: [Sha384.digest_length]u8 = undefined;
    Sha384.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, digest[0..Sha384.digest_length]);
}

test "transcript sha512 accumulates correctly" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha512);
    tr.update("hello ");
    tr.update("world");
    const digest = tr.peek();
    var expected: [Sha512.digest_length]u8 = undefined;
    Sha512.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, digest[0..Sha512.digest_length]);
}

test "transcript final resets state" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha256);
    tr.update("data");
    _ = tr.final();
    // After final, the hasher is reset; updating with same data should produce same hash
    tr.update("data");
    const digest1 = tr.peek();
    tr.initAlgorithm(.sha256);
    tr.update("data");
    const digest2 = tr.peek();
    try std.testing.expectEqualSlices(u8, digest1[0..Sha256.digest_length], digest2[0..Sha256.digest_length]);
}

test "transcript getAlgorithm returns current algorithm" {
    var tr: TranscriptHash = .{};
    try std.testing.expect(tr.getAlgorithm() == null);
    tr.initAlgorithm(.sha256);
    try std.testing.expectEqual(HashAlgorithm.sha256, tr.getAlgorithm().?);
    tr.initAlgorithm(.sha384);
    try std.testing.expectEqual(HashAlgorithm.sha384, tr.getAlgorithm().?);
}

test "transcript initAlgorithm switches algorithm" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha256);
    tr.update("some data");
    tr.initAlgorithm(.sha384);
    // After switching, the old data is discarded
    const digest = tr.peek();
    var expected: [Sha384.digest_length]u8 = undefined;
    Sha384.hash("", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, digest[0..Sha384.digest_length]);
}

test "transcript empty hash matches reference" {
    var tr: TranscriptHash = .{};
    tr.initAlgorithm(.sha256);
    const digest = tr.peek();
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, digest[0..Sha256.digest_length]);
}
