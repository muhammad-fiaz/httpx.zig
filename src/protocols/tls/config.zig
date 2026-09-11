//! Production-grade TLS configuration for Client and Server (RFC 8446, RFC 6066, RFC 7301).
//!
//! Safe defaults by construction:
//!   - TLS 1.3 preferred, TLS 1.2 supported
//!   - Peer certificate verification enabled by default
//!   - Hostname verification enabled by default
//!   - System trust store enabled by default
//!   - ALPN negotiation: h2, http/1.1

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const alpn = @import("alpn.zig");
pub const certMod = @import("certificate.zig");
pub const keyMod = @import("key.zig");
pub const trustMod = @import("trust_store.zig");
pub const errorsMod = @import("errors.zig");
pub const sessionMod = @import("session.zig");

pub const CertificateChain = certMod.CertificateChain;
pub const X509Certificate = certMod.X509Certificate;
pub const PrivateKey = keyMod.PrivateKey;
pub const TrustStore = trustMod.TrustStore;
pub const TrustMode = trustMod.TrustMode;
pub const TlsError = errorsMod.TlsError;

const fs_mod = @import("../../utils/fs.zig");

pub const TlsVersion = enum {
    tls12,
    tls13,
    both,
};

pub const ClientAuthMode = enum {
    disabled,
    optional,
    required,
};

/// Server-side TLS configuration.
pub const ServerConfig = struct {
    allocator: Allocator = undefined,

    /// Certificate PEM string or file path.
    certPem: ?[]const u8 = null,
    /// Private key PEM string or file path.
    keyPem: ?[]const u8 = null,

    /// Parsed certificate chain in DER format.
    certChain: ?CertificateChain = null,
    /// Parsed private key bytes (redacted from logs).
    privateKeyDer: ?[]u8 = null,

    /// Minimum and maximum supported TLS protocol versions.
    minVersion: TlsVersion = .tls12,
    maxVersion: TlsVersion = .tls13,

    /// Preference order for ALPN negotiation (h2, http/1.1).
    alpnProtocols: []const alpn.Protocol = &.{ .h2, .@"http/1.1" },

    /// Mutual TLS (mTLS) client certificate authentication mode.
    clientAuth: ClientAuthMode = .disabled,
    /// Client CA certificate PEM or file path for mTLS validation.
    clientCa: ?[]const u8 = null,
    /// Parsed client trust store for mTLS.
    clientTrustStore: ?TrustStore = null,
    /// Whether to allow cleartext HTTP requests on the TLS port (e.g. for dev/dual-mode).
    /// Defaults to false (strict HTTPS: plain HTTP gets 400 Bad Request).
    allowPlainHttp: bool = false,
    /// Session-ticket keys for TLS 1.3 resumption (stateless: no
    /// per-client storage). Null disables resumption: no tickets are
    /// issued and PSK offers fall back to full handshakes. Generate with
    /// `TicketKeys.generate()` and rotate periodically via `rotate`.
    ticketKeys: ?sessionMod.TicketKeys = null,
    /// Lifetime (seconds) stamped into issued session tickets.
    ticketLifetimeSecs: u32 = 7200,

    pub fn init(allocator: Allocator) ServerConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ServerConfig) void {
        if (self.certChain) |*c| c.deinit();
        if (self.privateKeyDer) |k| {
            std.crypto.secureZero(u8, k);
            self.allocator.free(k);
        }
        if (self.clientTrustStore) |*ts| ts.deinit();
        self.* = undefined;
    }

    /// Loads certificate and private key from PEM buffers or file paths.
    pub fn loadCertificates(self: *ServerConfig, certPemOrPath: []const u8, keyPemOrPath: []const u8) !void {
        var cert_buf: ?[]u8 = null;
        defer if (cert_buf) |b| self.allocator.free(b);
        const certData = if (std.mem.indexOf(u8, certPemOrPath, "-----BEGIN") != null)
            certPemOrPath
        else blk: {
            cert_buf = try fs_mod.readFileLimited(self.allocator, certPemOrPath, 10 * 1024 * 1024);
            break :blk cert_buf.?;
        };

        var key_buf: ?[]u8 = null;
        defer if (key_buf) |b| {
            std.crypto.secureZero(u8, b);
            self.allocator.free(b);
        };
        const key_data = if (std.mem.indexOf(u8, keyPemOrPath, "-----BEGIN") != null)
            keyPemOrPath
        else blk: {
            key_buf = try fs_mod.readFileLimited(self.allocator, keyPemOrPath, 10 * 1024 * 1024);
            break :blk key_buf.?;
        };

        self.certChain = try certMod.parseCertificateChainPem(self.allocator, certData);
        const parsed_key = try keyMod.parsePrivateKeyPem(self.allocator, key_data);
        self.privateKeyDer = parsed_key.der;
    }

    /// Returns true if server identity (certificate + private key) is loaded.
    pub fn hasIdentity(self: *const ServerConfig) bool {
        return self.certChain != null and self.privateKeyDer != null;
    }
};

/// Client-side TLS configuration.
pub const ClientConfig = struct {
    /// Verify peer certificate against trusted CAs. Default: true.
    verifyPeer: bool = true,
    /// Verify hostname against certificate SANs. Default: true.
    verifyHostname: bool = true,
    /// Trust store mode (system, custom, both, or none).
    trustMode: TrustMode = .systemAndCustom,
    /// Minimum TLS protocol version. Default: TLS 1.2.
    minVersion: TlsVersion = .tls12,
    /// Maximum TLS protocol version. Default: TLS 1.3.
    maxVersion: TlsVersion = .tls13,
    /// Protocols to offer in ALPN negotiation in preference order.
    alpnProtocols: []const alpn.Protocol = &.{ .h2, .@"http/1.1" },
    /// Custom CA certificate PEM string.
    caPem: ?[]const u8 = null,
    /// Custom CA certificate file path.
    caFile: ?[]const u8 = null,
    /// Client certificate PEM for mutual TLS (mTLS).
    clientCertPem: ?[]const u8 = null,
    /// Client private key PEM for mutual TLS (mTLS).
    clientKeyPem: ?[]const u8 = null,
    /// Explicit TrustStore pointer (if pre-configured).
    trustStore: ?*TrustStore = null,
};

// Backwards-compatible aliases
pub const parseCertificatePem = certMod.parseCertificateChainPem;
pub const parsePrivateKeyPem = certMod.decodePemBlock;

test "ServerConfig init and deinit" {
    const a = std.testing.allocator;
    var cfg = ServerConfig.init(a);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasIdentity());
}
