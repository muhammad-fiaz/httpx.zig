//! HTTPX Unified TLS & Cryptography Subsystem.
//!
//! Provides production-grade TLS 1.3 and 1.2 support for HTTP client and server:
//! - X.509 certificate parsing and validation
//! - Cross-platform system trust store integration (Windows, Linux, macOS)
//! - RFC 6125 strict hostname verification
//! - ALPN negotiation (h2, http/1.1)
//! - Server Name Indication (SNI)
//! - Mutual TLS (mTLS) client certificate authentication
//! - Secure private key handling with memory zeroing
//! - Optional OpenSSL backend integration

pub const config = @import("config.zig");
pub const certificate = @import("certificate.zig");
pub const trust_store = @import("trust_store.zig");
pub const verify = @import("verify.zig");
pub const key = @import("key.zig");
pub const errors = @import("errors.zig");
pub const openssl = @import("openssl.zig");
pub const alpn = @import("alpn.zig");
pub const record = @import("record.zig");
pub const handshake = @import("handshake.zig");
pub const engine = @import("engine.zig");
pub const transport = @import("transport.zig");
pub const tcpTls = @import("tcp_tls.zig");
pub const quicTls = @import("quic_tls.zig");

// Canonical types
pub const ServerConfig = config.ServerConfig;
pub const ClientConfig = config.ClientConfig;
pub const TlsVersion = config.TlsVersion;
pub const ClientAuthMode = config.ClientAuthMode;
pub const X509Certificate = certificate.X509Certificate;
pub const CertificateChain = certificate.CertificateChain;
pub const TrustStore = trust_store.TrustStore;
pub const TrustMode = trust_store.TrustMode;
pub const PrivateKey = key.PrivateKey;
pub const TlsError = errors.TlsError;
pub const Connection = transport.Connection;
pub const TlsServer = tcpTls.TlsServer;
pub const TlsServerConn = tcpTls.TlsServerConn;
pub const TlsServerConfig = tcpTls.TlsServerConfig;

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../server/lifecycle.zig");

pub const Identity = struct {
    cert_chain_pem: []const u8 = "",
    private_key_pem: []const u8 = "",
};

pub const ListenerConfig = struct {
    port: u16 = 0,
    host: []const u8 = "127.0.0.1",
    default_identity: ?Identity = null,
};

pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
};

/// High-level TLS server listener backed by httpx.Server.
pub const Listener = struct {
    allocator: Allocator,
    server: *lifecycle.Server,

    pub fn init(allocator: Allocator, io: std.Io, cfg: ListenerConfig) !Listener {
        const srv = try allocator.create(lifecycle.Server);
        errdefer allocator.destroy(srv);

        srv.* = try lifecycle.Server.init(allocator, io, .{
            .host = cfg.host,
            .port = cfg.port,
            .enableDocs = false,
            .tls = if (cfg.default_identity) |id| .{
                .certificate = id.cert_chain_pem,
                .private_key = id.private_key_pem,
            } else null,
        });

        return .{
            .allocator = allocator,
            .server = srv,
        };
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit();
        self.allocator.destroy(self.server);
    }

    pub fn localPort(self: *const Listener) u16 {
        return self.server.localPort();
    }

    pub fn run(self: *Listener, handler_fn: anytype) !void {
        _ = handler_fn;
        self.server.run();
    }

    pub fn stop(self: *Listener) void {
        self.server.stop();
    }
};

test {
    _ = config;
    _ = certificate;
    _ = trust_store;
    _ = verify;
    _ = key;
    _ = errors;
    _ = openssl;
    _ = alpn;
    _ = record;
    _ = handshake;
    _ = engine;
    _ = transport;
    _ = tcpTls;
    _ = quicTls;
}
