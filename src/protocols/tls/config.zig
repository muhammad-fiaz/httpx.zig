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
pub const cert_mod = @import("certificate.zig");
pub const key_mod = @import("key.zig");
pub const trust_mod = @import("trust_store.zig");
pub const errors_mod = @import("errors.zig");

pub const CertificateChain = cert_mod.CertificateChain;
pub const X509Certificate = cert_mod.X509Certificate;
pub const PrivateKey = key_mod.PrivateKey;
pub const TrustStore = trust_mod.TrustStore;
pub const TrustMode = trust_mod.TrustMode;
pub const TlsError = errors_mod.TlsError;

const c_fs = @import("../../web/static_files/serve.zig").c_fs;

pub fn readFileAlloc(a: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const h = c_fs.openRead(path) orelse return error.FileNotFound;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        var size: i64 = 0;
        if (c_fs.GetFileSizeEx(h, &size) == @as(std.os.windows.BOOL, @enumFromInt(0))) return error.IoError;
        const fsize: usize = @intCast(@max(0, size));
        if (fsize > max_size) return error.FileTooLarge;

        const buf = try a.alloc(u8, fsize);
        errdefer a.free(buf);

        var total: usize = 0;
        while (total < fsize) {
            var bytes_read: u32 = 0;
            const ok = c_fs.ReadFile(h, buf[total..].ptr, @intCast(@min(fsize - total, 0xFFFF_FFFF)), &bytes_read, null);
            if (ok == @as(std.os.windows.BOOL, @enumFromInt(0))) return error.IoError;
            if (bytes_read == 0) break;
            total += bytes_read;
        }
        if (total != fsize) return error.IoError;
        return buf;
    } else {
        const stat = std.posix.fstat(h) catch return error.IoError;
        const fsize: usize = @intCast(stat.size);
        if (fsize > max_size) return error.FileTooLarge;

        const buf = try a.alloc(u8, fsize);
        errdefer a.free(buf);

        var total: usize = 0;
        while (total < fsize) {
            const rc = std.c.read(h, buf[total..].ptr, fsize - total);
            if (rc <= 0) break;
            total += @intCast(rc);
        }
        if (total != fsize) return error.IoError;
        return buf;
    }
}

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
    certificate: ?[]const u8 = null,
    cert_pem: ?[]const u8 = null,
    /// Private key PEM string or file path.
    private_key: ?[]const u8 = null,
    key_pem: ?[]const u8 = null,

    /// Parsed certificate chain in DER format.
    cert_chain: ?CertificateChain = null,
    /// Parsed private key bytes (redacted from logs).
    private_key_der: ?[]u8 = null,

    /// Minimum and maximum supported TLS protocol versions.
    min_version: TlsVersion = .tls12,
    max_version: TlsVersion = .tls13,

    /// Preference order for ALPN negotiation (h2, http/1.1).
    alpn_protocols: []const alpn.Protocol = &.{ .h2, .@"http/1.1" },

    /// Mutual TLS (mTLS) client certificate authentication mode.
    client_auth: ClientAuthMode = .disabled,
    /// Client CA certificate PEM or file path for mTLS validation.
    client_ca: ?[]const u8 = null,
    /// Parsed client trust store for mTLS.
    client_trust_store: ?TrustStore = null,
    /// Whether to allow cleartext HTTP requests on the TLS port (e.g. for dev/dual-mode).
    /// Defaults to false (strict HTTPS: plain HTTP gets 400 Bad Request).
    allow_plain_http: bool = false,

    pub fn init(allocator: Allocator) ServerConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ServerConfig) void {
        if (self.cert_chain) |*c| c.deinit();
        if (self.private_key_der) |k| {
            std.crypto.secureZero(u8, k);
            self.allocator.free(k);
        }
        if (self.client_trust_store) |*ts| ts.deinit();
        self.* = undefined;
    }

    /// Loads certificate and private key from PEM buffers or file paths.
    pub fn loadCertificates(self: *ServerConfig, cert_pem_or_path: []const u8, key_pem_or_path: []const u8) !void {
        var cert_buf: ?[]u8 = null;
        defer if (cert_buf) |b| self.allocator.free(b);
        const cert_data = if (std.mem.indexOf(u8, cert_pem_or_path, "-----BEGIN") != null)
            cert_pem_or_path
        else blk: {
            cert_buf = try readFileAlloc(self.allocator, cert_pem_or_path, 10 * 1024 * 1024);
            break :blk cert_buf.?;
        };

        var key_buf: ?[]u8 = null;
        defer if (key_buf) |b| {
            std.crypto.secureZero(u8, b);
            self.allocator.free(b);
        };
        const key_data = if (std.mem.indexOf(u8, key_pem_or_path, "-----BEGIN") != null)
            key_pem_or_path
        else blk: {
            key_buf = try readFileAlloc(self.allocator, key_pem_or_path, 10 * 1024 * 1024);
            break :blk key_buf.?;
        };

        self.cert_chain = try cert_mod.parseCertificateChainPem(self.allocator, cert_data);
        const parsed_key = try key_mod.parsePrivateKeyPem(self.allocator, key_data);
        self.private_key_der = parsed_key.raw_der;
    }

    /// Returns true if server identity (certificate + private key) is loaded.
    pub fn hasIdentity(self: *const ServerConfig) bool {
        return self.cert_chain != null and self.private_key_der != null;
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
pub const parseCertificatePem = cert_mod.parseCertificateChainPem;
pub const parsePrivateKeyPem = cert_mod.decodePemBlock;

test "ServerConfig init and deinit" {
    const a = std.testing.allocator;
    var cfg = ServerConfig.init(a);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasIdentity());
}
