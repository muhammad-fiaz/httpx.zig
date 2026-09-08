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
    raw_der: []u8,
    allocator: Allocator,
    key_type: KeyType = .unknown,

    /// Releases the private key memory, performing a secure zero beforehand.
    pub fn deinit(self: *PrivateKey) void {
        if (self.raw_der.len > 0) {
            crypto.secureZero(u8, self.raw_der);
            self.allocator.free(self.raw_der);
        }
        self.* = undefined;
    }

    /// Returns the raw DER bytes of the private key.
    pub fn rawDer(self: PrivateKey) []const u8 {
        return self.raw_der;
    }

    /// Custom formatter to prevent accidental leaking of private keys into debug logs.
    pub fn format(self: PrivateKey, writer: anytype) !void {
        _ = self;
        try writer.writeAll("[REDACTED_PRIVATE_KEY]");
    }
};

/// Parses a private key from PEM bytes (PKCS#8, RSA PRIVATE KEY, or EC PRIVATE KEY).
pub fn parsePrivateKeyPem(allocator: Allocator, pem_bytes: []const u8) TlsError!PrivateKey {
    const labels = [_][]const u8{
        "PRIVATE KEY",
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
    };

    for (labels) |label| {
        if (std.mem.indexOf(u8, pem_bytes, label) != null) {
            const der = cert_mod.decodePemBlock(allocator, pem_bytes, label) catch continue;
            var key_type: KeyType = .unknown;
            if (std.mem.eql(u8, label, "RSA PRIVATE KEY")) {
                key_type = .rsa;
            } else if (std.mem.eql(u8, label, "EC PRIVATE KEY")) {
                key_type = .ecdsa_p256;
            }
            return PrivateKey{
                .raw_der = der,
                .allocator = allocator,
                .key_type = key_type,
            };
        }
    }

    return TlsError.PrivateKeyInvalid;
}

test "PrivateKey format redaction" {
    var key = PrivateKey{
        .raw_der = try std.testing.allocator.alloc(u8, 16),
        .allocator = std.testing.allocator,
        .key_type = .rsa,
    };
    defer key.deinit();

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{f}", .{key});
    try std.testing.expectEqualStrings("[REDACTED_PRIVATE_KEY]", str);
}
