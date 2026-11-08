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
//! - X25519MLKEM768 post-quantum key exchange
//!
//! This file is the entry point for the subsystem: every module in this
//! directory is reachable from here, either as a named value (`Client`,
//! `Server`, `Session`) or as a module alias (`record`, `engine`, ...).

const alpnMod = @import("alpn.zig");
const certificateMod = @import("certificate.zig");
const clientMod = @import("tlsClient.zig");
const configMod = @import("tlsConfig.zig");
const engineMod = @import("tlsEngine.zig");
const errorsMod = @import("tlsErrors.zig");
const handshakeMod = @import("tlsHandshake.zig");
const keyMod = @import("tlsKey.zig");
const quicTlsMod = @import("quicTls.zig");
const recordMod = @import("tlsRecord.zig");
const serverMod = @import("tlsServer.zig");
const sessionMod = @import("tlsSession.zig");
const transportMod = @import("tlsTransport.zig");
const trustStoreMod = @import("trustStore.zig");
const verifyMod = @import("certificateVerification.zig");
pub const ocsp = @import("ocsp.zig");
pub const sct = @import("sct.zig");
pub const pkcs12 = @import("pkcs12.zig");

/// TLS client owner: configuration, trust and identity, connection factory.
pub const Client = clientMod.Client;
/// TLS server owner: configuration, identity and mTLS trust, acceptor.
pub const Server = serverMod.Server;
/// A resumable TLS session (PSK identity), as captured from connections
/// and offered back for abbreviated handshakes.
pub const Session = sessionMod.ClientSession;
/// Origin-keyed resumption session cache (typically owned by the caller,
/// e.g. the HTTP connection pool).
pub const SessionCache = sessionMod.SessionCache;
/// Bounded anti-replay cache for TLS 1.3 0-RTT early data.
pub const ReplayCache = sessionMod.ReplayCache;
/// Server-side session-ticket encryption keys (stateless resumption).
pub const TicketKeys = sessionMod.TicketKeys;
pub const session = sessionMod;
/// A parsed X.509 certificate.
pub const Certificate = certificateMod.X509Certificate;
/// Trust anchor store (system and/or custom CAs).
pub const TrustStore = trustStoreMod.TrustStore;
pub const TrustMode = trustStoreMod.TrustMode;
/// Server-certificate verification policy.
pub const VerifyMode = transportMod.VerifyMode;
pub const TlsVersion = configMod.TlsVersion;
pub const ClientAuthMode = configMod.ClientAuthMode;
pub const TlsError = errorsMod.TlsError;
pub const AlpnProtocol = alpnMod.Protocol;

// Module aliases.
pub const alpn = alpnMod;
pub const certificate = certificateMod;
pub const config = configMod;
pub const engine = engineMod;
pub const errors = errorsMod;
pub const handshake = handshakeMod;
pub const key = keyMod;
pub const quicTls = quicTlsMod;
pub const record = recordMod;
pub const transport = transportMod;
pub const trustStore = trustStoreMod;
pub const verify = verifyMod;

const std = @import("std");

test {
    _ = clientMod;
    _ = serverMod;
    _ = sessionMod;
    _ = certificateMod;
    _ = trustStoreMod;
    _ = transportMod;
    _ = configMod;
    _ = errorsMod;
    _ = alpnMod;
}

test "local TLS handshake serves HTTPS end to end" {
    // Full TLS 1.3 crypto interop: std-based client against the native
    // server engine (negotiated ECDHE, ECDSA CertificateVerify, Finished on
    // both sides, then encrypted application data). Uses the committed
    // P-256 test identity; RSA keys are rejected loudly (no RSA private
    // operations in std).
    const httpClientMod = @import("../../client/httpClient.zig");
    const httpServerMod = @import("../../server/httpServer.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(_: *@import("../../web/router/router.zig").Context) anyerror!@import("../../web/router/router.zig").Response {
            return .{ .status = 200, .body = "tls-hello" };
        }
    };

    var server = try httpServerMod.Server.init(a, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
        .tls = .{
            .certificatePem = @embedFile("testdata/localhostCert.pem"),
            .privateKeyPem = @embedFile("testdata/localhostKey.pem"),
        },
    });
    defer server.deinit();

    try server.get("/", .{ .handler = H.handle });

    const port = server.localPort();
    const r = try server.start();
    defer {
        server.requestShutdown();
        r.join();
    }

    var client = httpClientMod.Client.init(a, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{ .tls = .{ .verify = .none, .allowTruncation = true }, .timeoutMs = 15_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("tls-hello", res.body);
}
