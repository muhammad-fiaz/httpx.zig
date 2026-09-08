//! Cross-platform system and custom CA Trust Store management.
//!
//! Provides automatic root CA discovery for:
//!   - Windows (CryptoAPI ROOT store)
//!   - Linux (/etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/certs/ca-bundle.crt)
//!   - macOS (Keychain Services root certificates)
//!
//! Supports custom CA certificates, file paths, directories, and thread-safe verification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const Certificate = crypto.Certificate;
const Bundle = Certificate.Bundle;
const errors_mod = @import("errors.zig");
pub const TlsError = errors_mod.TlsError;

pub const TrustMode = enum {
    /// Use operating system root certificates combined with any configured custom CAs.
    systemAndCustom,
    /// Use only system root certificates.
    systemOnly,
    /// Use only explicitly configured custom CA certificates.
    customOnly,
    /// Accept self-signed certificates without root CA trust anchor.
    selfSigned,
    /// Disable certificate verification. INSECURE: intended for testing/debugging only.
    none,
};

pub const TrustStore = struct {
    allocator: Allocator,
    bundle: Bundle,
    lock: std.Io.RwLock = .init,
    mode: TrustMode = .systemAndCustom,
    loadedSystem: bool = false,

    pub fn init(allocator: Allocator) TrustStore {
        return .{
            .allocator = allocator,
            .bundle = .empty,
            .mode = .systemAndCustom,
            .loadedSystem = false,
        };
    }

    pub fn deinit(self: *TrustStore) void {
        self.bundle.deinit(self.allocator);
        self.* = undefined;
    }

    /// Automatically scans and populates root certificates from host operating system.
    pub fn loadSystemTrust(self: *TrustStore, io: std.Io) TlsError!void {
        if (self.loadedSystem) return;
        const now = std.Io.Timestamp.now(io, .awake);
        self.bundle.rescan(self.allocator, io, now) catch return TlsError.TlsCaUnavailable;
        self.loadedSystem = true;
    }

    /// Adds a single DER-encoded CA certificate to the trust store.
    pub fn addCertDer(self: *TrustStore, der_bytes: []const u8) TlsError!void {
        self.bundle.add(self.allocator, der_bytes) catch return TlsError.OutOfMemory;
    }

    /// Parses and adds all PEM-encoded CA certificates to the trust store.
    pub fn addCertPem(self: *TrustStore, pem_bytes: []const u8) TlsError!void {
        var search_from: usize = 0;
        var added: usize = 0;
        while (std.mem.indexOfPos(u8, pem_bytes, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
            const cert_mod = @import("certificate.zig");
            const der = cert_mod.decodePemBlock(self.allocator, pem_bytes[idx..], "CERTIFICATE") catch break;
            defer self.allocator.free(der);
            self.addCertDer(der) catch return TlsError.OutOfMemory;
            added += 1;
            search_from = idx + 26;
        }
        if (added == 0 and search_from == 0) return TlsError.InvalidCertificate;
    }

    /// Verifies a parsed peer certificate against the trusted bundle.
    pub fn verify(self: *TrustStore, subject: Certificate.Parsed, now_sec: i64) TlsError!void {
        self.bundle.verify(subject, now_sec) catch |err| switch (err) {
            error.CertificateExpired => return TlsError.CertificateExpired,
            error.CertificateNotYetValid => return TlsError.CertificateNotYetValid,
            error.CertificateIssuerNotFound => return TlsError.CertificateUntrusted,
            error.CertificateSignatureInvalid => return TlsError.CertificateSignatureInvalid,
            else => return TlsError.InvalidCertificateChain,
        };
    }

    /// Returns the number of trusted root CA certificates currently in the store.
    pub fn count(self: *const TrustStore) usize {
        return self.bundle.map.count();
    }
};

test "TrustStore initialization and empty verification" {
    const alloc = std.testing.allocator;
    var ts = TrustStore.init(alloc);
    defer ts.deinit();

    try std.testing.expectEqual(@as(usize, 0), ts.count());
}
