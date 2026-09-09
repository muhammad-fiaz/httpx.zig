//! Secure Private Key management with memory zeroing and sensitive data protection.
//!
//! Supports PKCS#8, PKCS#1 (RSA), and SEC1 (EC) private keys in PEM or DER format.
//! Automatically clears sensitive memory upon deinitialization with std.crypto.secureZero.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const cert_mod = @import("certificate.zig");
const errors_mod = @import("errors.zig");
pub const TlsError = errors_mod.TlsError;

pub const KeyType = enum {
    rsa,
    ecdsa_p256,
    ecdsa_p384,
    ed25519,
    unknown,
};

pub const PrivateKey = struct {
    der: []u8,
    allocator: Allocator,
    keyType: KeyType = .unknown,

    /// Releases the private key memory, performing a secure zero beforehand.
    pub fn deinit(self: *PrivateKey) void {
        if (self.der.len > 0) {
            crypto.secureZero(u8, self.der);
            self.allocator.free(self.der);
        }
        self.* = undefined;
    }

    /// Returns the raw DER bytes of the private key.
    pub fn rawDer(self: PrivateKey) []const u8 {
        return self.der;
    }

    /// Custom formatter to prevent accidental leaking of private keys into debug logs.
    pub fn format(self: PrivateKey, writer: anytype) !void {
        _ = self;
        try writer.writeAll("[REDACTED_PRIVATE_KEY]");
    }
};

/// Parses a private key from PEM bytes (PKCS#8, RSA PRIVATE KEY, or EC PRIVATE KEY).
pub fn parsePrivateKeyPem(allocator: Allocator, pemBytes: []const u8) TlsError!PrivateKey {
    const labels = [_][]const u8{
        "PRIVATE KEY",
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
    };

    for (labels) |label| {
        if (std.mem.indexOf(u8, pemBytes, label) != null) {
            const der = cert_mod.decodePemBlock(allocator, pemBytes, label) catch continue;
            var keyType: KeyType = .unknown;
            if (std.mem.eql(u8, label, "RSA PRIVATE KEY")) {
                keyType = .rsa;
            } else if (std.mem.eql(u8, label, "EC PRIVATE KEY")) {
                keyType = .ecdsa_p256;
            }
            return PrivateKey{
                .der = der,
                .allocator = allocator,
                .keyType = keyType,
            };
        }
    }

    return TlsError.PrivateKeyInvalid;
}

test "PrivateKey format redaction" {
    var key = PrivateKey{
        .der = try std.testing.allocator.alloc(u8, 16),
        .allocator = std.testing.allocator,
        .keyType = .rsa,
    };
    defer key.deinit();

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{f}", .{key});
    try std.testing.expectEqualStrings("[REDACTED_PRIVATE_KEY]", str);
}
