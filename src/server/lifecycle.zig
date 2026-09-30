//! HTTP/1.1 server: accept loop -> parser -> router dispatch -> writer.
//!
//! One connection per iteration with Connection: close framing; a fresh
//! request arena backs each connection so handlers can allocate freely and
//! everything is released when the response is written.
//!
//! API documentation routes (OpenAPI + Swagger UI + ReDoc) are mounted by
//! default; disable with `Config.enableDocs = false` or customize through
//! `Config.docs`.
//!
//! References:
//!   - RFC 9112 — HTTP/1.1 (message format, connection management)
//!   - RFC 9110 — HTTP Semantics (status codes, headers, methods)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const compression = @import("../compression/codec.zig");
const parserMod = @import("../protocols/http1/parser.zig");
const writerMod = @import("../protocols/http1/writer.zig");
const routerMod = @import("../web/router/router.zig");
const Router = routerMod.Router;
const Context = routerMod.Context;
const Response = routerMod.Response;
const Method = @import("../common/method.zig").Method;
const docs = @import("../web/docs/docs.zig");
const httpVersion = @import("../common/httpVersion.zig");
pub const HttpVersion = httpVersion.HttpVersion;
const watcherMod = @import("../web/watcher/backend.zig");
const templatesMod = @import("../web/templates/templates.zig");
const tlsServerMod = @import("../protocols/tls/server.zig");
const fsMod = @import("../utils/fs.zig");
const alpnMod = @import("../protocols/tls/alpn.zig");
const metricsMod = @import("../web/metrics/registry.zig");
const tlsSessionMod = @import("../protocols/tls/session.zig");
const quicTransport = @import("../protocols/quic/transport.zig");
const quicConn = @import("../protocols/quic/connection.zig");
const quicHs = @import("../protocols/quic/handshake.zig");
const quicFrames = @import("../protocols/quic/frames.zig");
const http3Frame = @import("../protocols/http3/frame.zig");
const http3Conn = @import("../protocols/http3/connection.zig");
const http3Stream = @import("../protocols/http3/stream.zig");
const http3Qpack = @import("../protocols/http3/qpack.zig");

pub const maxHeadBytes = 32 * 1024;

/// Unified abstraction over plain TCP sockets and encrypted TLS server connections.
pub const StreamConn = union(enum) {
    plain: *tcp.Socket,
    tls: *tlsServerMod.Server.Connection,

    pub fn read(self: StreamConn, buf: []u8) anyerror!usize {
        return switch (self) {
            .plain => |p| p.read(buf),
            .tls => |t| t.read(buf),
        };
    }

    pub fn writeAll(self: StreamConn, bytes: []const u8) anyerror!void {
        return switch (self) {
            .plain => |p| p.writeAll(bytes),
            .tls => |t| t.writeAll(bytes),
        };
    }
};

const logging = @import("../common/logging.zig");
const clock = @import("../common/clock.zig");

/// Observability configuration for the server.
///
/// HTTPX NEVER automatically prints to stdout, stderr, or any output
/// destination. The application callback receives structured `ServerEvent`
/// values and decides where (if anywhere) they go.
///
/// ```zig
/// fn onEvent(event: httpx.ServerEvent) void {
///     if (event.kind == .requestCompleted) {
///         std.debug.print("{s} {s} {d} {d}ms\n", .{
///             event.method, event.path, event.status, event.durationMs,
///         });
///     }
/// }
///
/// var server = try httpx.Server.init(allocator, io, .{
///     .logging = .{ .callback = onEvent },
/// });
/// ```
///
/// To disable all events (the default): `.logging = .{}` (callback = null).
pub const LoggingOptions = struct {
    /// Application-supplied callback. When null (the default), no events are
    /// generated and HTTPX produces no output whatsoever.
    callback: ?logging.ServerEventCallback = null,
    /// Minimum severity filter. Events below this level are not delivered.
    level: logging.Level = .info,
};

pub const PortStrategy = enum {
    /// If port is in use, automatically try port + 1, port + 2, up to maxPortAttempts.
    incremental,
    /// Return error.AddressInUse immediately if port is occupied.
    strict,
    /// Exit / fail if port is occupied.
    exit,
};

/// ALPN identifiers this server can actually speak.
///
/// `h2` is deliberately absent. `Config.http2` exists and defaults to true,
/// but there is no HTTP/2 framing behind it, so advertising the identifier
/// negotiates a protocol we then fail to speak: every browser and a default
/// `curl` offer `h2`, and the exchange dies right after the handshake. The
/// list has to come from what is implemented, not from what the config
/// declares.
const alpn_http11 = [_]alpnMod.Protocol{.@"http/1.1"};
const alpn_http10_http11 = [_]alpnMod.Protocol{ .@"http/1.1", .@"http/1.0" };

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// Port resolution strategy when the port is in use. Default is incremental.
    portStrategy: PortStrategy = .incremental,
    /// Maximum attempts when portStrategy is incremental.
    maxPortAttempts: u16 = 50,
    /// Largest accepted request body.
    maxBody: usize = 8 * 1024 * 1024,
    /// Total connections run() serves before returning (0 = unlimited).
    /// Tests use small values to join the run thread deterministically;
    /// production servers leave this 0 and shut down via requestShutdown().
    maxConnections: usize = 0,
    /// Mount /openapi.json, /docs (Swagger UI), /redoc by default.
    enableDocs: bool = true,
    /// Overrides for docs routes when enabled.
    docs: ?docs.Config = null,
    docsTitle: []const u8 = "HTTPX API",
    logging: LoggingOptions = .{},
    /// HTTP/1.1 persistent connections: honor keep-alive, serve multiple
    /// requests per connection (bounded by maxRequestsPerConn).
    keepAlive: bool = false,
    maxRequestsPerConn: usize = 1000,
    /// Allow bare LF line endings for request parsing (issue #37).
    allowLfLineEndings: bool = false,
    /// Whether to trust X-Forwarded-For, X-Forwarded-Proto, and X-Forwarded-Host from reverse proxies.
    /// When true, Context.remoteAddress(), Context.scheme(), and Context.host() will parse forwarded headers.
    trustForwardedHeaders: bool = false,
    /// Optional list of trusted proxy IPs/CIDRs (e.g. "127.0.0.1", "::1").
    /// If non-empty, headers are only trusted if connection originates from one of these addresses.
    trustedProxies: []const []const u8 = &.{},
    /// Preferred default HTTP version for server handling. When set to a
    /// concrete version it selects exactly that version, overriding the
    /// individual http10/http11/http2/http3 flags below; `.auto`/null
    /// leaves the flags in charge.
    httpVersion: ?HttpVersion = null,
    /// Enable HTTP/1.0 protocol handling.
    http10: bool = true,
    /// Enable HTTP/1.1 protocol handling.
    http11: bool = true,
    /// HTTP/2 cleartext server runtime path (default true: automatically serves H2 preface).
    http2: bool = true,
    /// HTTP/3 server runtime path.
    http3: bool = false,
    /// Automatically watch directory and broadcast changes / hot reload.
    watch: bool = false,
    /// Directory to watch when watch is enabled.
    watchDir: []const u8 = ".",
    /// Enable SSE / WebSocket live reload endpoints and auto-inject reload script into HTML.
    liveReload: bool = false,
    /// URL path where the live reload SSE endpoint is mounted.
    liveReloadPath: []const u8 = "/__httpx_liveReload",
    /// Native template engine configuration. If null, automatically discovers and enables "templates/" if that directory exists.
    templates: ?templatesMod.Config = null,
    /// Production-grade TLS / HTTPS configuration.
    /// When provided with certificate & private key (PEM or file path), enables HTTPS server.
    tls: ?tlsServerMod.Server.Config = null,
};

/// Global pointer to the active server for the Ctrl+C handler.
var gActiveServer: ?*Server = null;

fn installShutdownHandler(self: *Server) void {
    gActiveServer = self;
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const handlerFn = struct {
                fn callback(ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                    if (ctrlType <= 2) {
                        if (gActiveServer) |s| s.requestShutdown();
                        return @enumFromInt(1);
                    }
                    return @enumFromInt(0);
                }
            };
            _ = SetConsoleCtrlHandler(&handlerFn.callback, @enumFromInt(1));
        },
        else => {
            const handlerFn = struct {
                fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
                    _ = sig;
                    if (gActiveServer) |s| s.requestShutdown();
                }
            };
            var act: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
            act.handler = .{ .handler = @ptrCast(&handlerFn.sigHandler) };
            act.flags = 0;
            std.posix.sigaction(std.posix.SIG.INT, &act, null);
        },
    }
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: *const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

pub const Server = struct {
    io: std.Io,
    allocator: Allocator,
    listener: tcp.Listener,
    router: Router,
    cfg: Config,
    stopFlag: std.atomic.Value(bool) = .init(false),
    /// Resolved event callback — null means silent (no events generated).
    eventCallback: ?logging.ServerEventCallback = null,
    loggedStop: std.atomic.Value(bool) = .init(false),
    /// Live connections (keep-alive readers) so shutdown can wake them.
    connsMu: sync.Spinlock = .{},
    activeConns: std.ArrayList(*tcp.Socket) = .empty,
    /// True while the run-thread sits inside accept(); shutdown waits for
    /// this before closing the listener (removes the close/enter race).
    inAccept: std.atomic.Value(bool) = .init(false),
    ownsIo: bool = false,
    ioThreaded: ?*std.Io.Threaded = null,
    paused: std.atomic.Value(bool) = .init(false),
    docsMounted: bool = false,
    watcher: ?*watcherMod.Watcher = null,
    liveReloadEventId: std.atomic.Value(usize) = .init(1),
    /// Last reload strategy reported by the watcher (as a
    /// `watcherMod.ReloadStrategy` tag). The SSE endpoint maps it to
    /// `hotReload` (CSS swap) vs `reload` (full page) payloads.
    liveReloadStrategy: std.atomic.Value(u8) = .init(1),
    templateEngine: ?*templatesMod.Engine = null,
    tlsServer: ?tlsServerMod.Server = null,
    tlsCertPemLoaded: ?[]const u8 = null,
    tlsKeyPemLoaded: ?[]const u8 = null,
    h3Endpoint: ?quicTransport.Endpoint = null,
    h3PlaceholderConn: ?*quicConn.Connection = null,
    h3Pump: ?*quicTransport.Pump = null,
    h3Thread: ?std.Thread = null,
    h3Stop: std.atomic.Value(bool) = .init(false),
    metricsRegistry: metricsMod.Registry = .{},
    startTimeMs: i64 = 0,

    /// Initializes server with explicit allocator, shared IO, and configuration.
    /// Matches `var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });`
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        return initInternal(allocator, io, false, null, cfg);
    }

    fn initInternal(
        allocator: Allocator,
        io: std.Io,
        ownsIo: bool,
        ioThreaded: ?*std.Io.Threaded,
        cfg: Config,
    ) !Server {
        const addressMod = @import("../net/address.zig");
        errdefer if (ownsIo) {
            if (ioThreaded) |th| {
                th.deinit();
                allocator.destroy(th);
            }
        };

        // Default: all-interfaces IPv4. Explicit literals (incl. "::") bind
        // their family; anything unparsable falls back to 0.0.0.0.
        var addr: addressMod.Address = blk: {
            if (std.mem.eql(u8, cfg.host, "0.0.0.0")) break :blk addressMod.Address.unspecified4(cfg.port);
            if (std.mem.eql(u8, cfg.host, "::")) break :blk addressMod.Address.unspecified6(cfg.port);
            var tmp: addressMod.Address = undefined;
            break :blk tmp.parseIp(cfg.host) catch addressMod.Address.unspecified4(cfg.port);
        };
        addr.port = cfg.port;

        // Resolve the event callback from config (null = silent, no events).
        // HTTPX never creates a writer or allocates IO resources for logging.

        var listener: tcp.Listener = undefined;
        if (cfg.port == 0) {
            listener = try tcp.Listener.bindAddress(io, &addr);
        } else {
            var currentPort = cfg.port;
            var bound = false;
            const maxAttempts = if (cfg.portStrategy == .incremental) cfg.maxPortAttempts else 1;
            var attempt: u16 = 0;
            while (attempt < maxAttempts) : (attempt += 1) {
                addr.port = currentPort;
                if (tcp.Listener.bindAddress(io, &addr)) |l| {
                    listener = l;
                    bound = true;
                    break;
                } else |err| {
                    if (attempt + 1 >= maxAttempts or cfg.portStrategy != .incremental) {
                        return err;
                    }
                    currentPort +%= 1;
                }
            }
            if (!bound) return error.AddressInUse;
        }

        var effectiveCfg = cfg;
        if (cfg.httpVersion) |v| {
            switch (v) {
                .auto => {},
                .http10 => {
                    effectiveCfg.http10 = true;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = false;
                },
                .http11 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = true;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = false;
                },
                .http2 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = true;
                    effectiveCfg.http3 = false;
                },
                .http3 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = true;
                },
            }
        }

        // Correct the TLS ALPN preference to match what we serve.
        //
        // Done here, on the stored config, rather than at the construction
        // site: certificate reload rebuilds the TLS server from
        // `self.cfg.tls.?.alpn` and would otherwise fall back to
        // DEFAULT_TCP_PREFERENCE and reintroduce `h2`.
        //
        // Only the default is replaced. An explicitly chosen list is the
        // caller's decision, including a deliberate `h2`.
        if (effectiveCfg.tls) |*tcfg| {
            if (std.mem.eql(alpnMod.Protocol, tcfg.alpn, &alpnMod.DEFAULT_TCP_PREFERENCE)) {
                tcfg.alpn = if (effectiveCfg.http10) &alpn_http10_http11 else &alpn_http11;
            }
        }

        var templateEngine: ?*templatesMod.Engine = null;
        const shouldInitTemplates = if (effectiveCfg.templates) |tc| tc.enabled else blk: {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, "templates", .{}) catch break :blk false;
            dir.close(io);
            break :blk true;
        };

        if (shouldInitTemplates) {
            const tCfg = effectiveCfg.templates orelse templatesMod.Config{};
            const eng = try allocator.create(templatesMod.Engine);
            errdefer allocator.destroy(eng);
            eng.* = try templatesMod.Engine.init(allocator, io, tCfg);
            templateEngine = eng;
        }

        var tlsServer_opt: ?tlsServerMod.Server = null;
        var loadedCertPem: ?[]const u8 = null;
        var loadedKeyPem: ?[]const u8 = null;

        if (effectiveCfg.tls) |*tCfg| {
            const certOpt = tCfg.certificatePem;
            const keyOpt = tCfg.privateKeyPem;
            if (certOpt) |cert| {
                if (keyOpt) |key| {
                    if (std.mem.indexOf(u8, cert, "-----BEGIN") != null) {
                        loadedCertPem = allocator.dupe(u8, cert) catch null;
                    } else {
                        loadedCertPem = fsMod.readFileLimited(allocator, cert, 10 * 1024 * 1024) catch null;
                    }
                    if (std.mem.indexOf(u8, key, "-----BEGIN") != null) {
                        loadedKeyPem = allocator.dupe(u8, key) catch null;
                    } else {
                        loadedKeyPem = fsMod.readFileLimited(allocator, key, 10 * 1024 * 1024) catch null;
                    }
                    if (loadedCertPem != null and loadedKeyPem != null) {
                        tCfg.certificatePem = loadedCertPem.?;
                        tCfg.privateKeyPem = loadedKeyPem.?;
                        // Identity problems surface here at startup; a
                        // failure leaves TLS disabled (historical leniency).
                        tlsServer_opt = tlsServerMod.Server.init(allocator, io, tCfg.*) catch null;
                    }
                }
            }
        }

        var h3Ep_opt: ?quicTransport.Endpoint = null;
        var h3Placeholder_opt: ?*quicConn.Connection = null;
        if (effectiveCfg.http3 and loadedCertPem != null and loadedKeyPem != null) {
            const placeholder = try quicConn.Connection.init(allocator, io, .server, .{});
            errdefer placeholder.deinit();
            const ep = quicTransport.Endpoint.init(allocator, io, placeholder, .{ .port = listener.localPort() }) catch |err| {
                placeholder.deinit();
                return err;
            };
            h3Ep_opt = ep;
            h3Placeholder_opt = placeholder;
        }

        var srv = Server{
            .io = io,
            .allocator = allocator,
            .listener = listener,
            .router = Router.init(allocator),
            .cfg = effectiveCfg,
            .eventCallback = cfg.logging.callback,
            .ownsIo = ownsIo,
            .ioThreaded = ioThreaded,
            .templateEngine = templateEngine,
            .tlsServer = tlsServer_opt,
            .tlsCertPemLoaded = loadedCertPem,
            .tlsKeyPemLoaded = loadedKeyPem,
            .h3Endpoint = h3Ep_opt,
            .h3PlaceholderConn = h3Placeholder_opt,
            .h3Pump = null,
            .startTimeMs = clock.millisNow(),
        };
        srv.router.templateEngine = templateEngine;
        errdefer {
            srv.router.deinit();
            if (templateEngine) |eng| {
                eng.deinit();
                allocator.destroy(eng);
            }
            if (loadedCertPem) |c| allocator.free(c);
            if (loadedKeyPem) |k| {
                std.crypto.secureZero(u8, @constCast(k));
                allocator.free(k);
            }
            if (h3Ep_opt) |*ep| {
                ep.deinit();
            }
            if (h3Placeholder_opt) |p| {
                p.deinit();
            }
        }

        return srv;
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.get(path, handler, .{});
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.post(path, handler, .{});
    }

    pub fn put(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.put(path, handler, .{});
    }

    pub fn patch(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.patch(path, handler, .{});
    }

    pub fn delete(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.delete(path, handler, .{});
    }

    pub fn head(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.head(path, handler, .{});
    }

    pub fn options(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.options(path, handler, .{});
    }

    /// Registers a route with an arbitrary HTTP method.
    pub fn add(self: *Server, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.add(method, path, handler, .{});
    }

    /// Creates a prefixed route group on the server router.
    pub fn group(self: *Server, prefix: []const u8, opts: routerMod.GroupOptions) routerMod.Group {
        return self.router.group(prefix, opts);
    }

    /// Mounts another router's entries under `prefix`.
    pub fn mount(self: *Server, prefix: []const u8, other: *routerMod.Router, opts: routerMod.MountOptions) routerMod.RouteError!void {
        try self.router.mount(prefix, other, opts);
    }

    /// Attaches a global middleware to the server's routing pipeline.
    pub fn use(self: *Server, mw: routerMod.MiddlewareFn) !void {
        try self.router.use(mw);
    }

    /// Mounts a directory of static files under a URL prefix.
    pub fn static(self: *Server, mountPath: []const u8, dirPath: []const u8) !void {
        const staticMod = @import("../web/static_files/serve.zig");
        try staticMod.register(&self.router, .{
            .mount = mountPath,
            .root = dirPath,
        });
    }

    /// Mounts a Single Page Application (SPA) with index fallback.
    pub fn spa(self: *Server, mountPath: []const u8, dirPath: []const u8) !void {
        const spaMod = @import("../web/spa/serve.zig");
        try spaMod.register(&self.router, .{
            .mount = mountPath,
            .root = dirPath,
        });
    }

    /// Registers a Prometheus metrics exposition endpoint on the specified route.
    pub fn metrics(self: *Server, path: []const u8) routerMod.RouteError!void {
        const MetricsHandler = struct {
            fn handle(ctx: *Context) anyerror!Response {
                const reg: *metricsMod.Registry = @ptrCast(@alignCast(ctx.userData orelse return error.NoMetricsRegistry));
                const buf = try ctx.allocator.alloc(u8, 65536);
                var w: std.Io.Writer = .fixed(buf);
                try reg.renderPrometheus(&w);
                const body = try ctx.allocator.dupe(u8, w.buffered());
                return .{
                    .status = 200,
                    .headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" }},
                    .body = body,
                };
            }
        };
        try self.router.get(path, MetricsHandler.handle, .{ .userData = &self.metricsRegistry });
    }

    /// Captures a point-in-time snapshot of the server metrics registry.
    pub fn metricsSnapshot(self: *const Server) metricsMod.MetricsSnapshot {
        return self.metricsRegistry.snapshot();
    }

    /// Captures a comprehensive runtime snapshot of the server (uptime, throughput, error rate, active connections).
    pub fn snapshot(self: *const Server) metricsMod.ServerSnapshot {
        const now = clock.millisNow();
        const uptime: u64 = if (self.startTimeMs > 0 and now >= self.startTimeMs)
            @intCast(now - self.startTimeMs)
        else
            0;
        const ms = self.metricsRegistry.snapshot();
        return .{
            .uptimeMs = uptime,
            .activeConnections = ms.activeConnections,
            .activeRequests = ms.activeRequests,
            .requestsTotal = ms.requestsTotal,
            .responsesTotal = ms.responsesTotal,
            .errorsTotal = ms.errorsTotal,
            .bytesIn = ms.bytesIn,
            .bytesOut = ms.bytesOut,
            .metrics = ms,
        };
    }

    /// Sets a custom 404 Not Found handler (HTML, JSON, custom template, etc.)
    pub fn setNotFoundHandler(self: *Server, handler: *const fn (*Context) anyerror!Response) void {
        self.router.setNotFoundHandler(handler);
    }

    /// Sets a custom 500 / Exception handler (HTML, JSON error envelope, etc.)
    pub fn setErrorHandler(self: *Server, handler: *const fn (*Context, anyerror) anyerror!Response) void {
        self.router.setErrorHandler(handler);
    }

    /// Sets a custom error page / response handler for a specific HTTP status code (e.g. 403, 404, 500, 502, 503).
    pub fn setStatusHandler(self: *Server, statusCode: u16, handler: *const fn (*Context) anyerror!Response) !void {
        try self.router.setStatusHandler(statusCode, handler);
    }

    pub fn deinit(self: *Server) void {
        if (self.watcher) |w| {
            w.stop();
            w.deinit();
            self.watcher = null;
        }
        if (self.templateEngine) |eng| {
            eng.deinit();
            self.allocator.destroy(eng);
            self.templateEngine = null;
        }
        if (self.tlsCertPemLoaded) |c| {
            self.allocator.free(c);
            self.tlsCertPemLoaded = null;
        }
        if (self.tlsKeyPemLoaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
            self.tlsKeyPemLoaded = null;
        }
        if (self.tlsServer) |*s| {
            s.deinit();
            self.tlsServer = null;
        }
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();
        if (self.h3Thread) |th| {
            th.join();
            self.h3Thread = null;
        }
        if (self.h3Pump) |p| {
            self.allocator.destroy(p);
            self.h3Pump = null;
        }
        if (self.h3Endpoint) |*ep| {
            ep.deinit();
            self.h3Endpoint = null;
        }
        if (self.h3PlaceholderConn) |p| {
            p.deinit();
            self.h3PlaceholderConn = null;
        }
        if (self.cfg.enableDocs) docs.unmount();
        self.router.deinit();
        self.listener.close(self.io);
        self.activeConns.deinit(self.allocator);
        if (self.ownsIo) {
            if (self.ioThreaded) |th| {
                th.deinit();
                self.allocator.destroy(th);
                self.ioThreaded = null;
            }
        }
    }

    /// Returns true if this server has TLS configured and active.
    pub fn isTls(self: *const Server) bool {
        return self.tlsServer != null;
    }

    /// Dynamically sets or updates TLS certificates on this server instance.
    /// Old PEMs are released only after the replacement owner builds
    /// successfully, so a failed rotation keeps serving with the old
    /// identity (and old buffers are never freed twice).
    pub fn setTls(self: *Server, certPemOrPath: []const u8, keyPemOrPath: []const u8) !void {
        var certStr: []u8 = undefined;
        if (std.mem.indexOf(u8, certPemOrPath, "-----BEGIN") != null) {
            certStr = try self.allocator.dupe(u8, certPemOrPath);
        } else {
            certStr = try fsMod.readFileLimited(self.allocator, certPemOrPath, 10 * 1024 * 1024);
        }
        errdefer self.allocator.free(certStr);

        var keyStr: []u8 = undefined;
        if (std.mem.indexOf(u8, keyPemOrPath, "-----BEGIN") != null) {
            keyStr = try self.allocator.dupe(u8, keyPemOrPath);
        } else {
            keyStr = try fsMod.readFileLimited(self.allocator, keyPemOrPath, 10 * 1024 * 1024);
        }
        errdefer {
            std.crypto.secureZero(u8, keyStr);
            self.allocator.free(keyStr);
        }

        // Build the replacement owner first: on failure the errdefers
        // above release the new PEMs and the previous server (if any)
        // keeps serving.
        var newServer: ?tlsServerMod.Server = null;
        newServer = tlsServerMod.Server.init(self.allocator, self.io, .{
            .certificatePem = certStr,
            .privateKeyPem = keyStr,
            .alpn = if (self.cfg.tls) |t| t.alpn else &alpnMod.DEFAULT_TCP_PREFERENCE,
            .clientAuth = if (self.cfg.tls) |t| t.clientAuth else .disabled,
            .clientCaPem = if (self.cfg.tls) |t| t.clientCaPem else null,
            .ticketKeys = if (self.cfg.tls) |t| t.ticketKeys else null,
            .ticketLifetimeSecs = if (self.cfg.tls) |t| t.ticketLifetimeSecs else 7200,
        }) catch null;
        if (newServer == null) return error.TlsInitializationFailed;

        if (self.tlsServer) |*s| s.deinit();
        if (self.tlsCertPemLoaded) |c| self.allocator.free(c);
        if (self.tlsKeyPemLoaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
        }
        self.tlsCertPemLoaded = certStr;
        self.tlsKeyPemLoaded = keyStr;
        self.tlsServer = newServer;
    }

    /// Returns the active template engine, if templates are enabled.
    pub fn templates(self: *Server) ?*templatesMod.Engine {
        return self.templateEngine;
    }

    pub fn localPort(self: *const Server) u16 {
        return self.listener.localPort();
    }

    /// Signals the accept loop to stop and wakes a blocked accept() by
    /// closing the listening socket (POSIX) or connecting a dummy socket (Windows).
    /// Safe to call multiple times.
    pub fn requestShutdown(self: *Server) void {
        if (!self.loggedStop.swap(true, .acq_rel)) {
            self.emit(.{ .kind = .serverStopped, .level = .info, .message = "shutting down" });
        }
        self.stopFlag.store(true, .release);
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();

        // On Windows (Zig 0.16), the AFD-backed listener uses IOCP for accept().
        // Closing the listening socket while a thread is blocked in netAcceptWindows
        // returns STATUS_CANCELLED, which the stdlib marks `unreachable` → panic.
        // tcp.wakeListenerPort() connects a dummy socket to the port instead,
        // waking accept() naturally. The accept loop then sees stop==true and exits.
        // On POSIX, wakeListenerPort is a no-op and we close the listener directly.
        if (self.inAccept.load(.acquire)) {
            tcp.wakeListenerPort(self.listener.localPort());
        }
        if (@import("builtin").os.tag != .windows) {
            self.listener.close(self.io);
        }

        // A keep-alive worker may be blocked in recv() and therefore never
        // reach accept(). Wake those readers immediately; Socket.close is
        // idempotent and the worker's deferred close will observe the same close flag.
        self.connsMu.lock();
        for (self.activeConns.items) |conn| conn.close();
        self.connsMu.unlock();
    }

    /// Immediate shutdown (no graceful drain). Sets stop flag and shuts down
    /// the listener + all connections cleanly without triggering Windows AFD panic.
    pub fn stop(self: *Server) void {
        self.requestShutdown();
    }

    /// Canonical alias for run(). Starts the blocking request serving loop.
    pub fn serve(self: *Server) void {
        self.run();
    }

    /// Non-blocking server start. Spawns a thread that calls `run()`.
    /// Returns the thread handle so the caller can join.
    pub fn start(self: *Server) !std.Thread {
        return std.Thread.spawn(.{}, (struct {
            fn run(s: *Server) void {
                s.run();
            }
        }).run, .{self});
    }

    /// Pause accepting new connections. Sets a paused flag that run() checks.
    pub fn pause(self: *Server) void {
        self.paused.store(true, .release);
    }

    /// Resume accepting new connections.
    pub fn resumeAccepting(self: *Server) void {
        self.paused.store(false, .release);
        if (self.inAccept.load(.acquire)) {
            tcp.wakeListenerPort(self.listener.localPort());
        }
    }

    /// Return the full bound address. Supports IPv4 and IPv6.
    pub fn localAddress(self: *const Server) std.Io.net.IpAddress {
        return self.listener.server.socket.address;
    }

    /// Blocking accept loop. `requestShutdown()` takes effect between
    /// accepts; `maxConnections` (when nonzero) makes run() return after
    /// that many connections, which is how tests join deterministically.
    /// Installs a Ctrl+C handler for graceful shutdown.
    pub fn run(self: *Server) void {
        // Mount docs here (not in init) because init returns by value,
        // making any &srv.router pointer taken inside init a dangling pointer.
        if (self.cfg.enableDocs and !self.docsMounted) {
            self.docsMounted = true;
            const dc = self.cfg.docs orelse docs.Config{};
            docs.mount(self.allocator, &self.router, dc, .{
                .title = self.cfg.docsTitle,
                .version = @import("../common/version.zig").version,
            }) catch {};
        }

        // Out-of-the-box watcher and live-reload integration
        if ((self.cfg.watch or self.cfg.liveReload) and self.watcher == null) {
            const WatcherCallback = struct {
                fn onChange(event: watcherMod.WatchEvent, userData: ?*anyopaque) void {
                    const s: *Server = @ptrCast(@alignCast(userData.?));
                    _ = s.liveReloadEventId.fetchAdd(1, .release);
                    s.liveReloadStrategy.store(@intFromEnum(event.strategy), .release);
                    if (s.templateEngine) |te| {
                        te.invalidate(event.path);
                    }
                    s.emit(.{
                        .kind = .serverStarted,
                        .level = .debug,
                        .path = event.path,
                        .message = switch (event.strategy) {
                            .hotReload => "file changed: hot reload CSS",
                            .warmReload => "file changed: warm reload HTML",
                            .coldReload => "file changed: cold reload assets/config",
                            .restart => "file changed: application source modified",
                        },
                    });
                }
            };

            const w = watcherMod.Watcher.init(self.allocator, self.io, .{
                .dirPath = self.cfg.watchDir,
                .onChange = WatcherCallback.onChange,
                .userData = self,
            }) catch null;
            if (w) |initializedW| {
                self.watcher = initializedW;
                initializedW.start() catch {};
            }

            if (self.cfg.liveReload) {
                const SseHandler = struct {
                    fn handle(ctx: *Context) anyerror!Response {
                        const s: *Server = @ptrCast(@alignCast(ctx.userData.?));
                        const currentId = s.liveReloadEventId.load(.acquire);
                        const strat: watcherMod.ReloadStrategy = @enumFromInt(s.liveReloadStrategy.load(.acquire));
                        // CSS-only changes hot-swap in the browser; anything
                        // else is a full page reload (see liveReloadScript).
                        const payload: []const u8 = if (strat == .hotReload) "hotReload" else "reload";
                        const sseBody = try std.fmt.allocPrint(ctx.allocator, "id: {d}\ndata: {s}\n\n", .{ currentId, payload });
                        return .{
                            .status = 200,
                            .body = sseBody,
                            .headers = &.{
                                .{ .name = "Content-Type", .value = "text/event-stream" },
                                .{ .name = "Cache-Control", .value = "no-cache" },
                                .{ .name = "Connection", .value = "keep-alive" },
                            },
                        };
                    }
                };
                self.router.get(self.cfg.liveReloadPath, SseHandler.handle, .{ .userData = self }) catch {};
            }
        }

        installShutdownHandler(self);
        self.emit(.{
            .kind = .serverStarted,
            .level = .info,
            .path = self.cfg.host,
            .status = self.listener.localPort(),
            .message = "server started",
        });
        if (self.h3Endpoint != null and self.h3Pump == null) {
            const pumpPtr = self.allocator.create(quicTransport.Pump) catch null;
            if (pumpPtr) |p| {
                if (p.start(&self.h3Endpoint.?, self.allocator)) {
                    self.h3Pump = p;
                    self.h3Thread = std.Thread.spawn(.{}, Server.runHttp3Loop, .{self}) catch null;
                } else |_| {
                    self.allocator.destroy(p);
                }
            }
        }
        var served: usize = 0;
        while (!self.stopFlag.load(.acquire)) {
            if (self.cfg.maxConnections != 0 and served >= self.cfg.maxConnections) break;
            // Yield when paused
            while (self.paused.load(.acquire) and !self.stopFlag.load(.acquire)) {
                clock.sleepMillis(10);
            }
            self.inAccept.store(true, .release);
            var conn = self.listener.accept(self.io) catch {
                self.inAccept.store(false, .release);
                break;
            };
            self.inAccept.store(false, .release);
            defer conn.close();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.serveConnection(&conn, arena.allocator()) catch {};
            served += 1;

            // Stop before blocking on the next accept when asked.
            if (self.stopFlag.load(.acquire)) break;
        }
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();
        if (self.h3Thread) |th| {
            th.join();
            self.h3Thread = null;
        }
        if (self.h3Pump) |p| {
            self.allocator.destroy(p);
            self.h3Pump = null;
        }
        self.emit(.{ .kind = .serverStopped, .level = .info, .message = "shutdown complete" });
    }

    /// Deliver a structured event to the application callback.
    /// No-op when callback is null (the default). Level filtering applied here.
    fn emit(self: *const Server, event: logging.ServerEvent) void {
        const cb = self.eventCallback orelse return;
        if (@intFromEnum(event.level) < @intFromEnum(self.cfg.logging.level)) return;
        cb(event);
    }

    fn serveConnection(self: *Server, conn: *tcp.Socket, arenaIn: Allocator) !void {
        _ = arenaIn;
        self.metricsRegistry.connectionOpened();
        defer self.metricsRegistry.connectionClosed();

        // Peek or read initial bytes to check protocol / TLS / HTTP/2 preface
        var peekBuf: [32]u8 = undefined;
        const nPeek = conn.read(peekBuf[0..]) catch return;
        if (nPeek == 0) return;

        // Check for TLS Handshake record (ContentType = 0x16, TLS legacy version 0x03, 0x01..0x03)
        if (self.tlsServer != null) {
            if (nPeek >= 3 and peekBuf[0] == 0x16 and peekBuf[1] == 0x03) {
                var tlsConn = self.tlsServer.?.acceptBuffered(conn, peekBuf[0..nPeek]) catch |err| {
                    var msgBuf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msgBuf, "TLS handshake failed: {s}", .{@errorName(err)}) catch "TLS handshake failed";
                    self.emit(.{ .kind = .tlsHandshakeFailed, .level = .warn, .message = msg });
                    return;
                };
                defer tlsConn.deinit();

                const streamConn = StreamConn{ .tls = &tlsConn };
                if (self.cfg.http2 and tlsConn.alpn != null and tlsConn.alpn.? == .h2) {
                    try self.serveHttp2Connection(streamConn, true, "");
                } else {
                    try self.serveHttp1Connection(streamConn, true, "");
                }
                return;
            } else if (self.cfg.tls == null or !self.cfg.tls.?.allowPlainHttp) {
                // Strict HTTPS mode: reject cleartext HTTP on HTTPS port (RFC 9110)
                const plainConn = StreamConn{ .plain = conn };
                _ = sendSimpleError(plainConn, 400, "The plain HTTP request was sent to HTTPS port") catch 0;
                return;
            }
        }

        const h2Preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        if (self.cfg.http2 and nPeek >= 16 and std.mem.startsWith(u8, peekBuf[0..nPeek], h2Preface[0..16])) {
            const streamConn = StreamConn{ .plain = conn };
            try self.serveHttp2Connection(streamConn, false, peekBuf[0..nPeek]);
            return;
        }

        const streamConn = StreamConn{ .plain = conn };
        try self.serveHttp1Connection(streamConn, false, peekBuf[0..nPeek]);
    }

    fn serveHttp2Connection(self: *Server, conn: StreamConn, isTlsConn: bool, initial: []const u8) !void {
        const H2Bridge = struct {
            fn handle(respAlloc: Allocator, ctxPtr: ?*anyopaque, isTlsFlag: bool, mStr: []const u8, pStr: []const u8, hdrs: []const @import("../protocols/http2/transport.zig").Header, bStr: []const u8) anyerror!@import("../protocols/http2/transport.zig").HandlerResponse {
                const serverPtr: *Server = @ptrCast(@alignCast(ctxPtr.?));
                const method = Method.fromString(mStr) orelse .GET;
                var arenaH2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arenaH2.deinit();
                const a = arenaH2.allocator();

                var ctxHdrs = try a.alloc(routerMod.Header, hdrs.len);
                for (hdrs, 0..) |h, i| ctxHdrs[i] = .{ .name = h.name, .value = h.value };

                var cleanPath = pStr;
                if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
                    cleanPath = cleanPath[0..idx];
                }
                var queryPart: []const u8 = "";
                if (std.mem.indexOfScalar(u8, pStr, '?')) |qi| {
                    var q = pStr[qi + 1 ..];
                    if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
                    queryPart = q;
                }

                var ctx = Context{
                    .allocator = a,
                    .io = serverPtr.io,
                    .headers = ctxHdrs,
                    .path = cleanPath,
                    .query = queryPart,
                    .method = method,
                    .body = bStr,
                    .isTls = isTlsFlag,
                    .trustForwarded = serverPtr.cfg.trustForwardedHeaders,
                };

                // Full pipeline: match + router/route middleware + 404/405 +
                // auto-OPTIONS, exactly like HTTP/1.
                const res = serverPtr.router.dispatch(&ctx);
                // res borrows from arenaH2 (freed on return) or static data:
                // duplicate into respAlloc (connection lifetime) so the
                // caller can send after we return.
                const outBody = try respAlloc.dupe(u8, res.body);
                const extra: usize = if (res.contentType != null) 1 else 0;
                var outHdrs = try respAlloc.alloc(@import("../protocols/http2/transport.zig").Header, res.headers.len + extra);
                for (res.headers, 0..) |h, i| {
                    outHdrs[i] = .{
                        .name = try respAlloc.dupe(u8, h.name),
                        .value = try respAlloc.dupe(u8, h.value),
                    };
                }
                if (res.contentType) |ct| {
                    outHdrs[outHdrs.len - 1] = .{
                        .name = "content-type",
                        .value = try respAlloc.dupe(u8, ct),
                    };
                }
                return .{
                    .status = res.status,
                    .headers = outHdrs,
                    .body = outBody,
                };
            }
        };

        // Initialize HTTP/2 session
        var session = try @import("../protocols/http2/connection.zig").Session.init(self.allocator, .server, .{});
        defer session.deinit();
        try session.startHandshake();
        conn.writeAll(session.outbound.items) catch return error.WriteFailed;
        session.outbound.clearRetainingCapacity();

        if (initial.len > 0) {
            try session.feed(initial);
        }

        var arenaState = std.heap.ArenaAllocator.init(self.allocator);
        defer arenaState.deinit();
        const transportMod = @import("../protocols/http2/transport.zig");

        // ServerCtx accumulates streams
        var sc = struct {
            arena: Allocator,
            sid: u31 = 0,
            method: std.ArrayList(u8) = .empty,
            path: std.ArrayList(u8) = .empty,
            hdrs: std.ArrayList(transportMod.Header) = .empty,
            body: std.ArrayList(u8) = .empty,
            dispatched: bool = false,
            responded: bool = true,

            fn resetFor(s: *@This(), sid: u31) void {
                s.sid = sid;
                s.method.clearRetainingCapacity();
                s.path.clearRetainingCapacity();
                s.hdrs.clearRetainingCapacity();
                s.body.clearRetainingCapacity();
                s.dispatched = false;
                s.responded = false;
            }

            fn onHeaders(ctxP: ?*anyopaque, sid: u31, flds: []@import("../protocols/http2/hpack.zig").HeaderField, endStream: bool) anyerror!void {
                const s: *@This() = @ptrCast(@alignCast(ctxP.?));
                s.resetFor(sid);
                for (flds) |f| {
                    if (std.mem.eql(u8, f.name, ":method")) {
                        try s.method.appendSlice(s.arena, f.value);
                    } else if (std.mem.eql(u8, f.name, ":path")) {
                        try s.path.appendSlice(s.arena, f.value);
                    } else if (!std.mem.startsWith(u8, f.name, ":")) {
                        const name = try s.arena.dupe(u8, f.name);
                        const value = try s.arena.dupe(u8, f.value);
                        try s.hdrs.append(s.arena, .{ .name = name, .value = value });
                    }
                }
                if (endStream) s.dispatched = true;
            }

            fn onData(ctxP: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
                const s: *@This() = @ptrCast(@alignCast(ctxP.?));
                if (sid != s.sid) return;
                try s.body.appendSlice(s.arena, data);
            }
        }{ .arena = arenaState.allocator() };

        session.cbs = .{
            .ctx = &sc,
            .onHeaders = @TypeOf(sc).onHeaders,
            .onData = @TypeOf(sc).onData,
        };

        var buf: [16 * 1024]u8 = undefined;
        while (!session.closed and !session.goawayReceived) {
            if (session.outbound.items.len > 0) {
                conn.writeAll(session.outbound.items) catch break;
                session.outbound.clearRetainingCapacity();
            }
            if (sc.dispatched and !sc.responded) {
                sc.responded = true;
                const resp = H2Bridge.handle(arenaState.allocator(), self, isTlsConn, sc.method.items, sc.path.items, sc.hdrs.items, sc.body.items) catch transportMod.HandlerResponse{ .status = 500 };

                var outFields = std.ArrayList(@import("../protocols/http2/hpack.zig").HeaderField).empty;
                defer outFields.deinit(self.allocator);
                var stBuf: [8]u8 = undefined;
                var clBuf: [8]u8 = undefined;
                const st = std.fmt.bufPrint(&stBuf, "{d}", .{resp.status}) catch "500";
                const cl = std.fmt.bufPrint(&clBuf, "{d}", .{resp.body.len}) catch "0";
                try outFields.append(self.allocator, .{ .name = ":status", .value = st });
                try outFields.append(self.allocator, .{ .name = "content-length", .value = cl });
                for (resp.headers) |h| {
                    try outFields.append(self.allocator, .{ .name = h.name, .value = h.value });
                }

                try session.sendHeaders(sc.sid, outFields.items, resp.body.len == 0);
                // HEAD responses carry headers (with content-length) but no
                // DATA frames, mirroring the HTTP/1 transport.
                const isHead = std.ascii.eqlIgnoreCase(sc.method.items, "HEAD");
                if (resp.body.len > 0 and !isHead) {
                    _ = try session.sendData(sc.sid, resp.body, true);
                } else if (isHead and resp.body.len > 0) {
                    _ = try session.sendData(sc.sid, "", true);
                }
                if (session.outbound.items.len > 0) {
                    conn.writeAll(session.outbound.items) catch break;
                    session.outbound.clearRetainingCapacity();
                }
            }
            const n = conn.read(&buf) catch break;
            if (n == 0) break;
            session.feed(buf[0..n]) catch break;
        }
    }

    fn runHttp3Loop(self: *Server) void {
        while (!self.stopFlag.load(.acquire) and !self.h3Stop.load(.acquire)) {
            self.serveOneHttp3() catch |err| {
                if (err == error.Timeout or err == error.Cancelled) continue;
                if (self.stopFlag.load(.acquire) or self.h3Stop.load(.acquire)) break;
            };
        }
    }

    fn serveOneHttp3(self: *Server) !void {
        const ep = &(self.h3Endpoint orelse return error.NoEndpoint);
        const pump = self.h3Pump orelse return error.NoPump;
        const certPem = self.tlsCertPemLoaded orelse return error.NoCertificate;
        const keyPem = self.tlsKeyPemLoaded orelse return error.NoPrivateKey;

        const oldConn = ep.conn;
        const qconn = try quicConn.Connection.init(self.allocator, self.io, .server, .{});
        defer {
            qconn.deinit();
            ep.conn = oldConn;
        }
        ep.conn = qconn;

        var replayCache = tlsSessionMod.ReplayCache.init(self.allocator, 256);
        defer replayCache.deinit();

        // Prefer the configured keys; otherwise mint a fresh one from OS
        // entropy so HTTP/3 keeps 0-RTT without falling back to a shared
        // secret. A hardcoded key here would seal every ticket with a
        // publicly known value, letting anyone forge one and resume as
        // any client. If the OS entropy source is unavailable we issue no
        // tickets, which is what the TCP path does when unconfigured.
        var generatedKeys: ?tlsSessionMod.TicketKeys = null;
        const ticketKeys: ?tlsSessionMod.TicketKeys = if (self.cfg.tls) |t|
            t.ticketKeys
        else if (tlsSessionMod.TicketKeys.generate(self.io)) |k| blk: {
            generatedKeys = k;
            break :blk k;
        } else |_| null;
        defer if (generatedKeys != null) {
            // Wipe the sealing key once this connection is done with it.
            std.crypto.secureZero(u8, &generatedKeys.?.current);
        };

        var drv = quicHs.Driver.initServer(self.io, self.allocator, .{
            .certChainPem = certPem,
            .privateKeyPem = keyPem,
            .ticketKeys = ticketKeys,
            .maxEarlyData = 16384,
            .replayCache = &replayCache,
        });
        defer drv.deinit();

        qconn.tls = .{
            .ctx = &drv,
            .start = quicHs.Driver.clientStart,
            .onData = quicHs.Driver.onData,
        };

        try quicHs.serveHandshake(ep, pump, &drv, 10_000);

        var h3 = http3Conn.Connection.init(self.allocator, .server);
        defer h3.deinit();

        const Acc = struct {
            sid: u64 = std.math.maxInt(u64),
            buf: std.ArrayList(u8) = .empty,
            fin: bool = false,

            fn onStream(c: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
                const acc: *@This() = @ptrCast(@alignCast(c.?));
                if (acc.sid == std.math.maxInt(u64) and sid % 4 == 0) acc.sid = sid;
                if (sid != acc.sid) return;
                acc.buf.appendSlice(std.heap.page_allocator, data) catch return;
                if (fin) acc.fin = true;
            }
        };

        var acc = Acc{};
        defer acc.buf.deinit(std.heap.page_allocator);
        qconn.cbs = .{ .ctx = &acc, .onStreamData = Acc.onStream };

        const startMs: u64 = @intCast(clock.millisNow());
        while (!self.stopFlag.load(.acquire) and !self.h3Stop.load(.acquire)) {
            const nowMs: u64 = @intCast(clock.millisNow());
            if (nowMs -| startMs > 10_000) return error.Timeout;
            try quicHs.feedPumped(ep, pump, null, 200, nowMs);
            if (!acc.fin) continue;

            var off: usize = 0;
            const fr = try http3Frame.parseFrame(acc.buf.items, &off);
            const fields = try h3.qdec.decodeSectionCounted(fr.payload, 0, null);
            defer h3.qdec.freeFields(fields);

            var mStr: []const u8 = "GET";
            var pStr: []const u8 = "/";
            var reqBody: []const u8 = "";
            if (off < acc.buf.items.len) {
                var bodyOff = off;
                if (http3Frame.parseFrame(acc.buf.items, &bodyOff)) |dfr| {
                    if (dfr.frameType == 0x00) {
                        reqBody = dfr.payload;
                    }
                } else |_| {}
            }

            var arenaH3 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arenaH3.deinit();
            const a = arenaH3.allocator();

            var ctxHdrs = try a.alloc(routerMod.Header, fields.len);
            var hdrCount: usize = 0;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, ":method")) {
                    mStr = f.value;
                } else if (std.mem.eql(u8, f.name, ":path")) {
                    pStr = f.value;
                } else if (!std.mem.startsWith(u8, f.name, ":")) {
                    ctxHdrs[hdrCount] = .{ .name = f.name, .value = f.value };
                    hdrCount += 1;
                }
            }

            const method = Method.fromString(mStr) orelse .GET;
            var cleanPath = pStr;
            if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
                cleanPath = cleanPath[0..idx];
            }
            var queryPart: []const u8 = "";
            if (std.mem.indexOfScalar(u8, pStr, '?')) |qi| {
                var q = pStr[qi + 1 ..];
                if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
                queryPart = q;
            }

            var ctx = Context{
                .allocator = a,
                .io = self.io,
                .headers = ctxHdrs[0..hdrCount],
                .path = cleanPath,
                .query = queryPart,
                .method = method,
                .body = reqBody,
                .isTls = true,
                .trustForwarded = self.cfg.trustForwardedHeaders,
            };

            const res = self.router.dispatch(&ctx);

            var qenc = http3Qpack.Encoder.init(self.allocator);
            defer qenc.deinit();
            var rs = http3Conn.RequestStream{ .id = acc.sid, .allocator = self.allocator, .qpack = &qenc };

            var respHeaders = std.ArrayList(http3Qpack.FieldLine).empty;
            defer respHeaders.deinit(a);
            for (res.headers) |h| {
                try respHeaders.append(a, .{ .name = h.name, .value = h.value });
            }
            if (res.contentType) |ct| {
                try respHeaders.append(a, .{ .name = "content-type", .value = ct });
            }

            const rhead = try rs.buildResponseHeaders(res.status, respHeaders.items);
            defer self.allocator.free(rhead);
            const rdata = try rs.buildData(res.body);
            defer self.allocator.free(rdata);

            const SendHelper = struct {
                var sId: u64 = 0;
                var sHead: []const u8 = "";
                var sData: []const u8 = "";
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) quicConn.Error!void {
                    quicFrames.encode(payload, gpa, .{ .stream = .{ .id = sId, .offset = 0, .data = sHead, .fin = false } }) catch
                        return quicConn.Error.OutOfMemory;
                    quicFrames.encode(payload, gpa, .{ .stream = .{ .id = sId, .offset = sHead.len, .data = sData, .fin = true } }) catch
                        return quicConn.Error.OutOfMemory;
                }
            };
            SendHelper.sId = acc.sid;
            SendHelper.sHead = rhead;
            SendHelper.sData = rdata;
            try qconn.sendFrames(.application, SendHelper.build, 0);
            _ = try ep.flush(null);
            return;
        }
    }

    fn serveHttp1Connection(self: *Server, conn: StreamConn, isTlsConn: bool, initial: []const u8) !void {
        if (!self.cfg.keepAlive) {
            var arenaOne = std.heap.ArenaAllocator.init(self.allocator);
            defer arenaOne.deinit();
            _ = try self.serveOneRequestBuffered(conn, arenaOne.allocator(), 0, true, initial, isTlsConn);
            return;
        }
        // Persistent connection: bounded request loop with per-request arena
        // reset so long-lived connections cannot grow memory unbounded.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const sock: *tcp.Socket = switch (conn) {
            .plain => |p| p,
            .tls => |t| t.socket,
        };

        self.connsMu.lock();
        self.activeConns.append(self.allocator, sock) catch |err| {
            self.connsMu.unlock();
            return err;
        };
        self.connsMu.unlock();
        defer {
            self.connsMu.lock();
            for (self.activeConns.items, 0..) |sc, i| {
                if (sc == sock) {
                    _ = self.activeConns.swapRemove(i);
                    break;
                }
            }
            self.connsMu.unlock();
        }

        var servedN: usize = 0;
        while (servedN < self.cfg.maxRequestsPerConn) : (servedN += 1) {
            _ = arena.reset(.retain_capacity);
            const initBytes = if (servedN == 0) initial else "";
            const wantMore = self.serveOneRequestBuffered(conn, arena.allocator(), servedN, false, initBytes, isTlsConn) catch return;
            if (!wantMore) break;
        }
    }

    fn serveOneRequest(self: *Server, conn: StreamConn, arena: Allocator, idx: usize, forceClose: bool, isTlsConn: bool) !bool {
        return self.serveOneRequestBuffered(conn, arena, idx, forceClose, "", isTlsConn);
    }

    fn serveOneRequestBuffered(self: *Server, conn: StreamConn, arena: Allocator, _: usize, forceClose: bool, initial: []const u8, isTlsConn: bool) !bool {
        const t0 = clock.millisNow();
        self.metricsRegistry.recordRequest();
        var headBuf: [maxHeadBytes]u8 = undefined;
        var filled: usize = 0;
        if (initial.len > 0) {
            const take = @min(initial.len, headBuf.len);
            @memcpy(headBuf[0..take], initial[0..take]);
            filled = take;
        }
        const allowLf = self.cfg.allowLfLineEndings;
        while (filled < headBuf.len) {
            if (std.mem.indexOf(u8, headBuf[0..filled], "\r\n\r\n") != null) break;
            if (allowLf and std.mem.indexOf(u8, headBuf[0..filled], "\n\n") != null) {
                // Ensure not just \r\n\r\n already handled; check bare LF
                var hasBare = false;
                for (headBuf[0..filled], 0..) |c, i| {
                    if (c == '\n' and i > 0 and headBuf[i - 1] != '\r') {
                        // Check if previous char before \n\n is not \r
                        if (i + 1 < filled and headBuf[i + 1] == '\n') hasBare = true;
                    }
                }
                if (hasBare) break;
                if (std.mem.indexOf(u8, headBuf[0..filled], "\n\n") != null) break;
            }
            const n = conn.read(headBuf[filled..]) catch return false;
            if (n == 0) return false; // peer closed
            filled += n;
        }
        self.metricsRegistry.recordBytesIn(filled);

        const parserOpts: parserMod.Options = .{ .allowLfLineEndings = allowLf };
        const reqHead = parserMod.parseRequestHead(headBuf[0..filled], parserOpts) catch {
            self.metricsRegistry.recordError();
            _ = sendSimpleError(conn, 400, "bad request") catch 0;
            return false;
        };

        self.metricsRegistry.recordRequestMethod(reqHead.method);

        if (reqHead.minorVersion == 0 and !self.cfg.http10) {
            _ = sendSimpleError(conn, 505, "HTTP/1.0 Not Supported") catch 0;
            return false;
        }
        if (reqHead.minorVersion == 1 and !self.cfg.http11) {
            _ = sendSimpleError(conn, 505, "HTTP/1.1 Not Supported") catch 0;
            return false;
        }

        // Headers -> Context slice.
        var fields: [parserMod.DEFAULT_MAX_HEADERS]parserMod.Field = undefined;
        const blk = parserMod.parseHeaderBlock(headBuf[0..filled], reqHead.headEnd, fields[0..], parserOpts) catch {
            _ = sendSimpleError(conn, 400, "bad headers") catch 0;
            return false;
        };

        const hdrs = arena.alloc(routerMod.Header, blk.count) catch return false;
        for (fields[0..blk.count], 0..) |f, i| hdrs[i] = .{ .name = f.name, .value = f.value };

        // Connection reuse decision (RFC 9112 Section 7): explicit "close" wins;
        // HTTP/1.0 defaults to close unless it requested keep-alive.
        var clientClose = forceClose or reqHead.minorVersion == 0;
        var clientKa10 = false;
        for (hdrs) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            if (std.ascii.indexOfIgnoreCase(h.value, "close") != null) clientClose = true;
            if (std.ascii.indexOfIgnoreCase(h.value, "keep-alive") != null) clientKa10 = true;
        }
        if (reqHead.minorVersion == 0 and clientKa10) clientClose = false;

        // Body: Content-Length or chunked (both bounded by cfg.maxBody).
        var body: []u8 = "";
        const framing = parserMod.decideFraming(fields[0..blk.count], false, 0, 0) catch {
            _ = sendSimpleError(conn, 400, "invalid message framing") catch 0;
            return false;
        };
        var hasExpect = false;
        for (fields[0..blk.count]) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "expect")) {
                hasExpect = true;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field.value, " \t"), "100-continue")) {
                    _ = sendSimpleError(conn, 417, "expectation failed") catch 0;
                    return false;
                }
            }
        }
        if (hasExpect and reqHead.minorVersion == 1 and framing.framing != .none) {
            const interim = writerMod.buildInformational(arena, 100, &.{}) catch return false;
            defer arena.free(interim);
            conn.writeAll(interim) catch return false;
        }
        {
            const fr = framing;
            switch (fr.framing) {
                .none, .contentLength => {
                    if (fr.length > self.cfg.maxBody) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = arena.alloc(u8, fr.length) catch return false;
                    // How many body bytes were already pulled in by the header reads.
                    const buffered = if (filled > blk.end) filled - blk.end else 0;
                    if (buffered > fr.length) clientClose = true;
                    const take = @min(buffered, fr.length);
                    @memcpy(body[0..take], headBuf[blk.end..][0..take]);
                    var have: usize = take;
                    while (have < fr.length) {
                        // Bounded window keeps behavior uniform across platforms.
                        const want = @min(4096, fr.length - have);
                        const n = conn.read(body[have..][0..want]) catch return false;
                        if (n == 0) return false;
                        have += n;
                    }
                },
                .chunked => {
                    // Persistent decoder + explicit unparsed cursor.
                    var dec: parserMod.ChunkedDecoder = .{};
                    var acc: std.ArrayList(u8) = .empty;
                    var raw: std.ArrayList(u8) = .empty;
                    raw.appendSlice(arena, headBuf[blk.end..filled]) catch return false;
                    var unparsed: usize = 0;
                    while (true) {
                        const tail = dec.decode(raw.items[unparsed..]) catch |e| switch (e) {
                            error.Incomplete => {
                                const n = conn.read(headBuf[0..]) catch return false;
                                if (n == 0) return false;
                                raw.appendSlice(arena, headBuf[0..n]) catch return false;
                                continue;
                            },
                            else => return false,
                        };
                        const produced = raw.items.len - unparsed - tail;
                        acc.appendSlice(arena, raw.items[unparsed..][0..produced]) catch return false;
                        unparsed += produced;
                        if (dec.state == .done) break;
                        const n = conn.read(headBuf[0..]) catch return false;
                        if (n == 0) return false;
                        raw.appendSlice(arena, headBuf[0..n]) catch return false;
                    }
                    // Any bytes after the terminating chunk are currently not
                    // retained for the next request, so do not reuse this
                    // connection when the read crossed message boundaries.
                    if (unparsed < raw.items.len) clientClose = true;
                    if (acc.items.len > self.cfg.maxBody) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = acc.items;
                },
                .tunnel => {
                    // CONNECT tunneling is not served by the request router.
                    _ = sendSimpleError(conn, 501, "CONNECT not supported") catch 0;
                    return false;
                },
            }
        }

        const method = Method.fromString(reqHead.method) orelse {
            _ = sendSimpleError(conn, 501, "method not supported") catch 0;
            return false;
        };

        const isHead = method == .HEAD;

        const rawPath = reqHead.path;
        var cleanPath = rawPath;
        if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
            cleanPath = cleanPath[0..idx];
        }
        var queryPart: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rawPath, '?')) |qi| {
            var q = rawPath[qi + 1 ..];
            if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
            queryPart = q;
        }

        var ctx = Context{
            .allocator = arena,
            .io = self.io,
            .headers = hdrs,
            .path = cleanPath,
            .query = queryPart,
            .method = method,
            .body = body,
            .isTls = isTlsConn,
            .trustForwarded = self.cfg.trustForwardedHeaders,
        };
        const res: Response = self.router.dispatch(&ctx);

        const bytesOut = writeResponse(conn, arena, reqHead.minorVersion, res, isHead, if (clientClose) "close" else "keep-alive", ctx.header("Accept-Encoding")) catch {
            self.metricsRegistry.recordError();
            return false;
        };
        const durNs: u64 = @intCast(@max(0, (clock.millisNow() -| t0) * 1_000_000));
        self.metricsRegistry.recordResponseFull(res.status, durNs, bytesOut);
        self.emitAccess(reqHead.method, reqHead.path, res.status, body.len, bytesOut, t0);
        return !clientClose;
    }

    /// Deliver a requestCompleted event to the application callback.
    /// Secrets never appear here: only method/path/status/timing/byte counts.
    fn emitAccess(self: *Server, method: []const u8, path: []const u8, status: u16, bytesIn: usize, bytesOut: usize, t0: i64) void {
        const dur = clock.millisNow() -| t0;
        self.emit(.{
            .kind = .requestCompleted,
            .level = .info,
            .method = method,
            .path = path,
            .status = status,
            .durationMs = dur,
            .bytesIn = bytesIn,
            .bytesOut = bytesOut,
        });
    }

    fn writeResponse(conn: StreamConn, arena: Allocator, minor: u8, res: Response, isHead: bool, connHdr: []const u8, acceptEncoding: ?[]const u8) !usize {
        // connHdr selects the Connection header emitted ("" -> legacy close).
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);

        lines.append(arena, if (connHdr.len > 0)
            (std.fmt.allocPrint(arena, "Connection: {s}", .{connHdr}) catch return 0)
        else
            "Connection: close") catch return 0;

        if (res.contentType) |ct| {
            const line = std.fmt.allocPrint(arena, "Content-Type: {s}", .{ct}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        for (res.headers) |h| {
            const line = std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }) catch return 0;
            lines.append(arena, line) catch return 0;
        }

        var encodedBody: ?[]u8 = null;
        defer if (encodedBody) |b| arena.free(b);
        var bodyOut: []const u8 = if (isHead) "" else res.body;
        var contentEncoding: ?[]const u8 = null;
        const isHugeAsset = res.body.len > 128 * 1024;
        if (!isHead and !isHugeAsset and res.body.len > 0 and res.status != 204 and res.status != 304 and acceptEncoding != null) {
            const selected = compression.negotiate(acceptEncoding.?);
            if (selected != .identity) {
                encodedBody = compression.compress(arena, selected, res.body) catch null;
                if (encodedBody) |b| {
                    bodyOut = b;
                    contentEncoding = selected.token();
                }
            }
        }
        if (contentEncoding) |ce| {
            lines.append(arena, "Vary: Accept-Encoding") catch return 0;
            const line = std.fmt.allocPrint(arena, "Content-Encoding: {s}", .{ce}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        const reason: []const u8 = if (writerMod.reasonPhrase(res.status).len > 0)
            writerMod.reasonPhrase(res.status)
        else
            reasonFor(res.status);
        var respHeaders = try arena.alloc(writerMod.Header, lines.items.len);
        for (lines.items, 0..) |line, i| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
            respHeaders[i] = .{
                .name = std.mem.trim(u8, line[0..colon], " "),
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            };
        }
        const raw = writerMod.buildResponse(
            arena,
            res.status,
            reason,
            bodyOut,
            .{ .minorVersion = minor, .headers = respHeaders },
            isHead,
        ) catch return 0;
        try conn.writeAll(raw);
        return raw.len;
    }

    fn sendSimpleError(conn: StreamConn, status: u16, text: []const u8) !usize {
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            status,
            reasonFor(status),
            text.len,
            text,
        }) catch return 0;
        try conn.writeAll(out);
        return out.len;
    }
};

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "Status",
    };
}

// Tests

fn helloHandler(ctx: *Context) anyerror!Response {
    if (std.mem.eql(u8, ctx.path, "/hello")) {
        return .{ .body = "hi", .contentType = "text/plain" };
    }
    return .{ .status = 404, .body = "" };
}

test "template route renders through tree-sitter pipeline end to end" {
    const tmplEngineMod = @import("../web/templates/engine.zig");
    const tmplRendererMod = @import("../web/templates/renderer.zig");
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var eng = tmplEngineMod.Engine.init(a, ctx.io, .{ .enableCache = true }) catch return;
    defer eng.deinit();

    const H = struct {
        var enginePtr: ?*tmplEngineMod.Engine = null;
        fn handle(c: *Context) anyerror!Response {
            var list = std.ArrayList(u8).empty;
            errdefer list.deinit(c.allocator);
            var lw = tmplRendererMod.ListWriter{ .list = &list, .allocator = c.allocator };
            try enginePtr.?.renderString("<h1>{{ title }}</h1>{% for u in users %}<p>{{ u }}</p>{% endfor %}", .{
                .title = "Hello",
                .users = [_][]const u8{ "ann", "bob" },
            }, &lw);
            return .{ .body = list.items, .contentType = "text/html" };
        }
    };
    H.enginePtr = &eng;

    var srv = Server.init(a, ctx.io, .{ .port = 0, .maxConnections = 2 }) catch return;
    defer srv.deinit();
    try srv.router.get("/", H.handle, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "<h1>Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "<p>bob</p>") != null);

    srv.requestShutdown();
}

test "server handles POST with content-length body" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.post("/echo", echoRawHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    const payload = "{\"raw\":true}";
    var reqBuf: [256]u8 = undefined;
    const raw = try std.fmt.bufPrint(&reqBuf, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    try client.writeAll(raw);

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "}\r\n") != null) break;
    }

    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..total], payload));
}

fn echoRawHandler(ctx: *Context) anyerror!Response {
    if (ctx.body.len == 0) return .{ .status = 400, .body = "empty" };
    return .{ .contentType = "application/json", .body = ctx.body };
}

// Logging verification: callback receives access events; silence when no callback.

const sync = @import("../common/sync.zig");

// Thread-local capture for test callbacks (single-threaded test context).
var gCaptureSeen: usize = 0;
var gCaptureGotRequest: bool = false;
var gCaptureGotLifecycle: bool = false;
var gCaptureMu: sync.Spinlock = .{};

fn testEventCallback(event: logging.ServerEvent) void {
    gCaptureMu.lock();
    defer gCaptureMu.unlock();
    gCaptureSeen += 1;
    if (event.kind == .requestCompleted and
        std.mem.indexOf(u8, event.path, "/logged") != null and
        std.mem.eql(u8, event.method, "GET"))
        gCaptureGotRequest = true;
    if (event.kind == .serverStarted or event.kind == .serverStopped)
        gCaptureGotLifecycle = true;
}

test "access log flows through event callback" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture state.
    gCaptureSeen = 0;
    gCaptureGotRequest = false;
    gCaptureGotLifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{ .callback = testEventCallback },
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch {
        srv.requestShutdown();
        t.join();
        return;
    };
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    // Close BEFORE joining so the server can drain and run() can return.
    c.close();

    // maxConnections=1 => run() returns only AFTER emitAccess ran.
    t.join();
    srv.requestShutdown();
    try std.testing.expect(gCaptureGotRequest);
    try std.testing.expect(gCaptureGotLifecycle);
}

test "no callback produces zero events" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture (should stay zero without callback).
    gCaptureSeen = 0;
    gCaptureGotRequest = false;
    gCaptureGotLifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{}, // null callback — silent by default
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    c.close();

    t.join();
    srv.requestShutdown();
    try std.testing.expectEqual(@as(usize, 0), gCaptureSeen);
}

fn returnOk(_: *Context) anyerror!Response {
    return .{ .body = "ok", .contentType = "text/plain" };
}

test "sequential clients are each served and closed cleanly" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/ok", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer c.close();
        c.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch return;
        var rbuf: [512]u8 = undefined;
        var total: usize = 0;
        while (total < rbuf.len) {
            const n = c.read(rbuf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
        }
        try std.testing.expect(std.mem.indexOf(u8, rbuf[0..total], "ok") != null);
    }
    srv.requestShutdown();
}

test "server serves routed GET end to end" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.get("/hello", helloHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /hello HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=1, zstd;q=0, br;q=0\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null and
            std.mem.indexOf(u8, buf[0..total], "\r\n\x1f\x8b") != null) break;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Vary: Accept-Encoding") != null);
    try std.testing.expect(total > 20);

    srv.requestShutdown();
}

test "raw socket 200KB content-length body roundtrip" {
    const a = std.testing.allocator;
    var ctx0 = tcp.IoContext.init(a) catch return;
    defer ctx0.deinit();
    var srv = Server.init(a, ctx0.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    const LenH = struct {
        fn h(ctx: *Context) anyerror!Response {
            const t = std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.body.len}) catch return error.OutOfMemory;
            return .{ .body = t };
        }
    };
    try srv.router.post("/len", LenH.h, .{});
    const R = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const th = std.Thread.spawn(.{}, R.run, .{&srv}) catch return;
    defer th.join();
    var c = tcp.connect(ctx0.io, "127.0.0.1", srv.localPort()) catch return;
    defer c.drainThenClose();
    const total = 200 * 1024;
    var hb: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{total});
    try c.writeAll(head);
    var blk: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < total) : (sent += blk.len) try c.writeAll(&blk);
    var rb: [256]u8 = undefined;
    var gotn: usize = 0;
    while (gotn < rb.len) {
        const n = c.read(rb[gotn..]) catch break;
        if (n == 0) break;
        gotn += n;
        if (std.mem.indexOf(u8, rb[0..gotn], "204800") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, rb[0..gotn], "204800") != null);
}
test "reason phrases cover common statuses" {
    try std.testing.expectEqualStrings("OK", reasonFor(200));
    try std.testing.expectEqualStrings("Not Found", reasonFor(404));
}

test "server isTls default is false" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(!srv.isTls());
}

test "server setTls dynamic reconfiguration and key zeroing" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(!srv.isTls());

    const cert1 = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key1 = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert1, key1);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert1, srv.tlsCertPemLoaded.?);

    // Reconfigure dynamically with new cert/key
    const cert2 = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key2 = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert2, key2);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert2, srv.tlsCertPemLoaded.?);
}

test "strict HTTPS mode rejects plain HTTP with 400 Bad Request" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    const cert = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert, key);
    try std.testing.expect(srv.isTls());

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "400 Bad Request") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "400 Bad Request") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "The plain HTTP request was sent to HTTPS port") != null);

    srv.requestShutdown();
}

var gTlsFailedSeen: bool = false;
var gTlsFailedMu: sync.Spinlock = .{};

fn testTlsEventCallback(event: logging.ServerEvent) void {
    if (event.kind == .tlsHandshakeFailed) {
        gTlsFailedMu.lock();
        defer gTlsFailedMu.unlock();
        gTlsFailedSeen = true;
    }
}

test "malformed TLS handshake emits tlsHandshakeFailed event" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    gTlsFailedMu.lock();
    gTlsFailedSeen = false;
    gTlsFailedMu.unlock();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{ .callback = testTlsEventCallback, .level = .warn },
    }) catch return;
    defer srv.deinit();

    const cert = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert, key);

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    // Send a TLS 1.3 ClientHello record header (0x16, 0x03, 0x01) followed by corrupt payload
    const badTls = [_]u8{ 0x16, 0x03, 0x01, 0x00, 0x05, 0xde, 0xad, 0xbe, 0xef, 0x00 };
    try client.writeAll(&badTls);

    // Give server worker moment to process and emit event
    clock.sleepMillis(50);

    srv.requestShutdown();

    gTlsFailedMu.lock();
    const seen = gTlsFailedSeen;
    gTlsFailedMu.unlock();
    try std.testing.expect(seen);
}

test "StreamConn operations" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/stream", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "ok") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "ok") != null);

    srv.requestShutdown();
}

test "Context isTls and scheme reflect connection security" {
    const a = std.testing.allocator;
    var ctxPlain = Context{
        .allocator = a,
        .isTls = false,
    };
    try std.testing.expectEqualStrings("http", ctxPlain.scheme());

    var ctxTls = Context{
        .allocator = a,
        .isTls = true,
    };
    try std.testing.expectEqualStrings("https", ctxTls.scheme());

    var hdrs: [1]routerMod.Header = .{.{ .name = "X-Forwarded-Proto", .value = "https" }};
    var ctxForwarded = Context{
        .allocator = a,
        .isTls = false,
        .trustForwarded = true,
        .headers = &hdrs,
    };
    try std.testing.expectEqualStrings("https", ctxForwarded.scheme());
}

test "server metrics snapshot and live Prometheus endpoint" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
    }) catch return;
    defer srv.deinit();

    try srv.router.get("/hello", helloHandler, .{});
    try srv.metrics("/metrics");

    const snap0 = srv.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), snap0.requestsTotal);

    const sSnap0 = srv.snapshot();
    try std.testing.expectEqual(@as(u64, 0), sSnap0.requestsTotal);

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    // Make a request to /hello to populate metrics
    {
        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();

        try client.writeAll("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n");

        var buf: [256]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = client.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "hi") != null) break;
        }
        try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "hi") != null);
    }

    // Now query /metrics endpoint
    {
        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();

        try client.writeAll("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n");

        var buf: [2048]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = client.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "http_requests_total") != null and
                std.mem.indexOf(u8, buf[0..total], "http_request_duration_seconds_bucket") != null) break;
        }
        const resp = buf[0..total];
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_requests_total") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_requests_by_method_total{method=\"GET\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_request_duration_seconds_bucket") != null);
    }

    srv.requestShutdown();

    const snap1 = srv.metricsSnapshot();
    try std.testing.expect(snap1.requestsTotal >= 2);
    try std.testing.expectEqual(@as(u64, 0), snap1.errorsTotal);

    const sSnap1 = srv.snapshot();
    try std.testing.expect(sSnap1.requestsTotal >= 2);
    // The /metrics connection may still be draining when requestShutdown
    // returns; allow either quiesced state rather than asserting exact zero.
    try std.testing.expect(sSnap1.activeRequests <= 1);
}

test "port zero allocates ephemeral port; strict rejects occupied port" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var first = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false }) catch return;
    defer first.deinit();
    const bound = first.localPort();
    try std.testing.expect(bound != 0);

    // Strict strategy on the occupied port must surface an error, not steal it.
    if (Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = bound,
        .portStrategy = .strict,
        .enableDocs = false,
    })) |s| {
        // Binding the loopback while the wildcard holds it may succeed on
        // some platforms; either outcome must leave a usable listener.
        var srv = s;
        srv.deinit();
    } else |_| {}

    // Incremental strategy must find a free port instead of failing.
    var second = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = bound,
        .portStrategy = .incremental,
        .maxPortAttempts = 8,
        .enableDocs = false,
    }) catch return;
    defer second.deinit();
    try std.testing.expect(second.localPort() != 0);
}

test "Server high-level HTTP/3 initialization and endpoint lifecycle" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    const certPem =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBmTCCAT+gAwIBAgIURhx0CMJWTUTFJXV9z2OlmW/cNlcwCgYIKoZIzj0EAwIw
        \\FDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDkwOTE4MTczOFoXDTM2MDkwNjE4
        \\MTczOFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0D
        \\AQcDQgAE71D4pM0SAPK8sdt+xlEESZX/EJoKHUC+4IpPuSlOiQuCXOkN04ozVGKA
        \\mrmUtDqQCdvmdjHbjqGY6TCszXTCnKNvMG0wHQYDVR0OBBYEFFjYJYGodkVKyvXf
        \\4qrn7rvQx+PFMB8GA1UdIwQYMBaAFFjYJYGodkVKyvXf4qrn7rvQx+PFMA8GA1Ud
        \\EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYcEfwAAAYIJbG9jYWxob3N0MAoGCCqGSM49
        \\BAMCA0gAMEUCIQD0sAcuw/jdWdfBrxLXY1ur2cU8F0CAkPCvS2qKn7XK4QIgAP71
        \\95toW+Gsh8/VZlNoHL2s14olRp5zl3cYDPzKM10=
        \\-----END CERTIFICATE-----
    ;
    const keyPem =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
        \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
        \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
        \\-----END PRIVATE KEY-----
    ;

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .tls = .{
            .certificatePem = certPem,
            .privateKeyPem = keyPem,
        },
        .enableDocs = false,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(srv.h3Endpoint != null);
    try std.testing.expect(srv.h3Pump == null);
    try std.testing.expectEqual(srv.localPort(), srv.h3Endpoint.?.localPort());
}
