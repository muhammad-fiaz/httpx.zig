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
pub const trustStore = @import("trustStore.zig");
pub const verify = @import("verify.zig");
pub const key = @import("key.zig");
pub const errors = @import("errors.zig");
pub const alpn = @import("alpn.zig");
pub const record = @import("record.zig");
pub const handshake = @import("handshake.zig");
pub const engine = @import("engine.zig");
pub const transport = @import("transport.zig");
pub const tcpTls = @import("tcpTls.zig");
pub const tcpClient = @import("tcpClient.zig");
pub const quicTls = @import("quicTls.zig");
pub const session = @import("session.zig");

// Canonical types
pub const ServerConfig = config.ServerConfig;
pub const ClientConfig = config.ClientConfig;
pub const TlsVersion = config.TlsVersion;
pub const ClientAuthMode = config.ClientAuthMode;
pub const X509Certificate = certificate.X509Certificate;
pub const CertificateChain = certificate.CertificateChain;
pub const TrustStore = trustStore.TrustStore;
pub const TrustMode = trustStore.TrustMode;
pub const PrivateKey = key.PrivateKey;
pub const TlsError = errors.TlsError;
pub const Connection = transport.Connection;
pub const TlsServer = tcpTls.TlsServer;
pub const TlsServerConn = tcpTls.TlsServerConn;
pub const TlsServerConfig = tcpTls.TlsServerConfig;
pub const TlsClient = tcpClient.TlsClient;
pub const TlsClientConn = tcpClient.TlsClientConn;
pub const TlsClientConfig = tcpClient.TlsClientConfig;
pub const ClientSession = session.ClientSession;
pub const TicketKeys = session.TicketKeys;

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../server/lifecycle.zig");
const router_mod = @import("../../web/router/router.zig");
const method_mod = @import("../../common/method.zig");

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
    ticketKeys: ?session.TicketKeys = null,
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
                .certPem = id.certChainPem,
                .keyPem = id.privateKeyPem,
                .clientAuth = cfg.clientAuth,
                .clientCa = cfg.clientCaPem,
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
        inline for ([_]method_mod.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS }) |m| {
            try self.server.router.add(m, "/", adapter, .{ .userData = self });
            try self.server.router.add(m, "/*path", adapter, .{ .userData = self });
        }
        self.server.run();
    }

    fn adapter(ctx: *router_mod.Context) anyerror!router_mod.Response {
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
    _ = config;
    _ = certificate;
    _ = trustStore;
    _ = verify;
    _ = key;
    _ = errors;
    _ = alpn;
    _ = record;
    _ = handshake;
    _ = engine;
    _ = transport;
    _ = tcpTls;
    _ = quicTls;
}

test "Listener.run wires handler for all requests" {
    const client_mod = @import("../../client/client.zig");
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

    var client = client_mod.Client.init(a, io, .{});
    defer client.deinit();

    var url_buf: [96]u8 = undefined;
    const get_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/anything?x=1", .{port});
    var res = try client.get(get_url, .{ .timeoutMs = 10_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("Hello over TLS!", res.body);

    const post_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/echo", .{port});
    var res2 = try client.post(post_url, .{ .body = "ping", .timeoutMs = 10_000 });
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
    const client_mod = @import("../../client/client.zig");
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
            .certChainPem = @embedFile("testdata/localhost_cert.pem"),
            .privateKeyPem = @embedFile("testdata/localhost_key.pem"),
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

    var client = client_mod.Client.init(a, io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{ .tls = .{ .verify = .none, .allowTruncation = true }, .timeoutMs = 15_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("tls-hello", res.body);
}
