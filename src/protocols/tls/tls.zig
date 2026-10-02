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
const clientMod = @import("client.zig");
const configMod = @import("config.zig");
const engineMod = @import("engine.zig");
const errorsMod = @import("errors.zig");
const handshakeMod = @import("handshake.zig");
const keyMod = @import("key.zig");
const quicTlsMod = @import("quicTls.zig");
const recordMod = @import("record.zig");
const serverMod = @import("server.zig");
const sessionMod = @import("session.zig");
const transportMod = @import("transport.zig");
const trustStoreMod = @import("trustStore.zig");
const verifyMod = @import("verify.zig");

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
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../server/lifecycle.zig");
const routerMod = @import("../../web/router/router.zig");
const methodMod = @import("../../common/method.zig");

pub const Identity = struct {
    certChainPem: []const u8 = "",
    privateKeyPem: []const u8 = "",
};

pub const ListenerConfig = struct {
    port: u16 = 0,
    host: []const u8 = "127.0.0.1",
    defaultIdentity: ?Identity = null,
    /// Mutual TLS mode (`.disabled`, `.optional`, `.required`).
    clientAuth: ClientAuthMode = .disabled,
    /// PEM bundle (or file path) of CAs trusted for client certificates.
    clientCaPem: ?[]const u8 = null,
    /// Session-ticket keys enabling TLS 1.3 resumption. Null disables
    /// tickets (clients always do full handshakes).
    ticketKeys: ?sessionMod.TicketKeys = null,
    /// Lifetime (seconds) stamped into issued session tickets.
    ticketLifetimeSecs: u32 = 7200,
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
///
/// `run` wires `handlerFn` (a `*const fn (Request) anyerror!Response`) to a
/// wildcard route for every method, so the single handler serves all paths.
/// Register-once: calling `run` twice returns `error.DuplicateRoute`.
pub const Listener = struct {
    allocator: Allocator,
    server: *lifecycle.Server,
    handler: ?*const fn (Request) anyerror!Response = null,

    pub fn init(allocator: Allocator, io: std.Io, cfg: ListenerConfig) !Listener {
        const srv = try allocator.create(lifecycle.Server);
        errdefer allocator.destroy(srv);

        srv.* = try lifecycle.Server.init(allocator, io, .{
            .host = cfg.host,
            .port = cfg.port,
            .enableDocs = false,
            .tls = if (cfg.defaultIdentity) |id| .{
                .certificatePem = id.certChainPem,
                .privateKeyPem = id.privateKeyPem,
                .clientAuth = cfg.clientAuth,
                .clientCaPem = cfg.clientCaPem,
                .ticketKeys = cfg.ticketKeys,
                .ticketLifetimeSecs = cfg.ticketLifetimeSecs,
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

    pub fn run(self: *Listener, handlerFn: anytype) !void {
        const f: *const fn (Request) anyerror!Response = handlerFn;
        self.handler = f;
        // One wildcard per method: the single handler serves every path,
        // including query strings (stripped by the router for matching).
        // The bare "/" is registered too: like static mounts, "/*path"
        // needs at least one segment, so it never matches the root.
        inline for ([_]methodMod.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS }) |m| {
            try self.server.router.add(m, "/", adapter, .{ .userData = self });
            try self.server.router.add(m, "/*path", adapter, .{ .userData = self });
        }
        self.server.run();
    }

    fn adapter(ctx: *routerMod.Context) anyerror!routerMod.Response {
        const self: *Listener = @ptrCast(@alignCast(ctx.userData orelse return error.NoHandler));
        const h = self.handler orelse return error.NoHandler;
        const res = try h(.{
            .method = ctx.method.toString(),
            .path = ctx.path,
            .body = ctx.body,
        });
        // Borrow rules: response slices must live in the request arena.
        const body = try ctx.allocator.dupe(u8, res.body);
        return .{ .status = res.status, .body = body };
    }

    pub fn stop(self: *Listener) void {
        self.server.stop();
    }
};

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

test "Listener.run wires handler for all requests" {
    const httpClientMod = @import("../../client/client.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(req: Request) anyerror!Response {
            if (std.mem.eql(u8, req.path, "/echo")) {
                return .{ .status = 201, .body = req.body };
            }
            return .{ .status = 200, .body = "Hello over TLS!" };
        }
    };

    // No identity: plain HTTP transport, same routing pipeline as HTTPS.
    var listener = try Listener.init(a, io, .{ .port = 0 });
    defer listener.deinit();

    const port = listener.localPort();
    const Runner = struct {
        fn run(l: *Listener) void {
            l.run(H.handle) catch {};
        }
    };
    const r = try std.Thread.spawn(.{}, Runner.run, .{&listener});
    defer r.join();
    defer listener.stop();

    var client = httpClientMod.Client.init(a, io, .{});
    defer client.deinit();

    var urlBuf: [96]u8 = undefined;
    const getUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/anything?x=1", .{port});
    var res = try client.get(getUrl, .{ .timeoutMs = 10_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("Hello over TLS!", res.body);

    const postUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/echo", .{port});
    var res2 = try client.post(postUrl, .{ .body = "ping", .timeoutMs = 10_000 });
    defer res2.deinit();
    try std.testing.expectEqual(@as(u16, 201), res2.status);
    try std.testing.expectEqualStrings("ping", res2.body);
}

test "local TLS handshake serves HTTPS end to end" {
    // Full TLS 1.3 crypto interop: std-based client against the native
    // server engine (negotiated ECDHE, ECDSA CertificateVerify, Finished on
    // both sides, then encrypted application data). Uses the committed
    // P-256 test identity; RSA keys are rejected loudly (no RSA private
    // operations in std).
    const httpClientMod = @import("../../client/client.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(req: Request) anyerror!Response {
            _ = req;
            return .{ .status = 200, .body = "tls-hello" };
        }
    };

    var listener = try Listener.init(a, io, .{
        .port = 0,
        .defaultIdentity = .{
            .certChainPem = @embedFile("testdata/localhostCert.pem"),
            .privateKeyPem = @embedFile("testdata/localhostKey.pem"),
        },
    });
    defer listener.deinit();

    const port = listener.localPort();
    const Runner = struct {
        fn run(l: *Listener) void {
            l.run(H.handle) catch {};
        }
    };
    const r = try std.Thread.spawn(.{}, Runner.run, .{&listener});
    defer r.join();
    defer listener.stop();

    var client = httpClientMod.Client.init(a, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{ .tls = .{ .verify = .none, .allowTruncation = true }, .timeoutMs = 15_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("tls-hello", res.body);
}
