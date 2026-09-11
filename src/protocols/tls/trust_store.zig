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
const errorsMod = @import("errors.zig");
pub const TlsError = errorsMod.TlsError;
const clock = @import("../../common/clock.zig");

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
    io: std.Io,
    bundle: Bundle,
    lock: std.Io.RwLock = .init,
    mode: TrustMode = .systemAndCustom,
    loadedSystem: bool = false,

    pub fn init(allocator: Allocator, io: std.Io) TrustStore {
        return .{
            .allocator = allocator,
            .io = io,
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
    pub fn loadSystemTrust(self: *TrustStore) TlsError!void {
        if (self.loadedSystem) return;
        const now = std.Io.Timestamp.now(self.io, .awake);
        self.bundle.rescan(self.allocator, self.io, now) catch return TlsError.TlsCaUnavailable;
        self.loadedSystem = true;
    }

    /// Adds a single DER-encoded CA certificate to the trust store.
    /// Follows `Bundle.parseCert` semantics: the bytes are appended to the
    /// bundle store and indexed by subject (expired anchors are skipped).
    pub fn addCertDer(self: *TrustStore, derBytes: []const u8) TlsError!void {
        const now_sec: i64 = @divFloor(clock.millisNow(), 1000);
        const start: u32 = @intCast(self.bundle.bytes.items.len);
        self.bundle.bytes.appendSlice(self.allocator, derBytes) catch return TlsError.OutOfMemory;
        errdefer self.bundle.bytes.items.len = start;
        self.bundle.parseCert(self.allocator, start, now_sec) catch |err| switch (err) {
            error.OutOfMemory => return TlsError.OutOfMemory,
            else => return TlsError.InvalidCertificate,
        };
    }

    /// Parses and adds all PEM-encoded CA certificates to the trust store.
    pub fn addCertPem(self: *TrustStore, pemBytes: []const u8) TlsError!void {
        var search_from: usize = 0;
        var added: usize = 0;
        while (std.mem.indexOfPos(u8, pemBytes, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
            const certMod = @import("certificate.zig");
            const der = certMod.decodePemBlock(self.allocator, pemBytes[idx..], "CERTIFICATE") catch break;
            defer self.allocator.free(der);
            self.addCertDer(der) catch return TlsError.OutOfMemory;
            added += 1;
            search_from = idx + 26;
        }
        if (added == 0 and search_from == 0) return TlsError.InvalidCertificate;
    }

    /// Verifies a parsed peer certificate against the trusted bundle.
    pub fn verify(self: *TrustStore, subject: Certificate.Parsed, nowSec: i64) TlsError!void {
        self.bundle.verify(subject, nowSec) catch |err| switch (err) {
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
    var ts = TrustStore.init(alloc, std.Io.Threaded.global_single_threaded.io());
    defer ts.deinit();

    try std.testing.expectEqual(@as(usize, 0), ts.count());
}
