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
const parser_mod = @import("../protocols/http1/parser.zig");
const writer_mod = @import("../protocols/http1/writer.zig");
const router_mod = @import("../web/router/router.zig");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Response = router_mod.Response;
const Method = @import("../common/method.zig").Method;
const docs = @import("../web/docs/docs.zig");
const http_version = @import("../common/http_version.zig");
pub const HttpVersion = http_version.HttpVersion;
const watcher_mod = @import("../web/watcher/watcher.zig");
const templates_mod = @import("../web/templates/templates.zig");
const tcp_tls_mod = @import("../protocols/tls/tcp_tls.zig");
const tls_config_mod = @import("../protocols/tls/config.zig");
const alpn_mod = @import("../protocols/tls/alpn.zig");
const metrics_mod = @import("../web/metrics/registry.zig");

pub const max_head_bytes = 32 * 1024;

/// Unified abstraction over plain TCP sockets and encrypted TLS server connections.
pub const StreamConn = union(enum) {
    plain: *tcp.Socket,
    tls: *tcp_tls_mod.TlsServerConn,

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
///     if (event.kind == .request_completed) {
///         std.debug.print("{s} {s} {d} {d}ms\n", .{
///             event.method, event.path, event.status, event.duration_ms,
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
    /// If port is in use, automatically try port + 1, port + 2, up to max_port_attempts.
    incremental,
    /// Return error.AddressInUse immediately if port is occupied.
    strict,
    /// Exit / fail if port is occupied.
    exit,
};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// Port resolution strategy when the port is in use. Default is incremental.
    port_strategy: PortStrategy = .incremental,
    /// Maximum attempts when port_strategy is incremental.
    max_port_attempts: u16 = 50,
    /// Largest accepted request body.
    max_body: usize = 8 * 1024 * 1024,
    /// Maximum concurrent connections. 0 = unlimited.
    max_connections: usize = 0,
    /// Mount /openapi.json, /docs (Swagger UI), /redoc by default.
    enableDocs: bool = true,
    /// Overrides for docs routes when enabled.
    docs: ?docs.Config = null,
    docs_title: []const u8 = "HTTPX API",
    logging: LoggingOptions = .{},
    /// HTTP/1.1 persistent connections: honor keep-alive, serve multiple
    /// requests per connection (bounded by max_requests_per_conn).
    keep_alive: bool = false,
    max_requests_per_conn: usize = 1000,
    /// Allow bare LF line endings for request parsing (issue #37).
    allow_lf_line_endings: bool = false,
    /// Whether to trust X-Forwarded-For, X-Forwarded-Proto, and X-Forwarded-Host from reverse proxies.
    /// When true, Context.remoteAddress(), Context.scheme(), and Context.host() will parse forwarded headers.
    trust_forwarded_headers: bool = false,
    /// Optional list of trusted proxy IPs/CIDRs (e.g. "127.0.0.1", "::1").
    /// If non-empty, headers are only trusted if connection originates from one of these addresses.
    trusted_proxies: []const []const u8 = &.{},
    /// Preferred default HTTP version for server handling (if specified, enforces version).
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
    watch_dir: []const u8 = ".",
    /// Enable SSE / WebSocket live reload endpoints and auto-inject reload script into HTML.
    live_reload: bool = false,
    /// URL path where the live reload SSE endpoint is mounted.
    live_reload_path: []const u8 = "/__httpx_live_reload",
    /// Native template engine configuration. If null, automatically discovers and enables "templates/" if that directory exists.
    templates: ?templates_mod.Config = null,
    /// Production-grade TLS / HTTPS configuration.
    /// When provided with certificate & private key (PEM or file path), enables HTTPS server.
    tls: ?tls_config_mod.ServerConfig = null,
};

/// Global pointer to the active server for the Ctrl+C handler.
var g_active_server: ?*Server = null;

fn installShutdownHandler(self: *Server) void {
    g_active_server = self;
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const handler_fn = struct {
                fn callback(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                    if (ctrl_type <= 2) {
                        if (g_active_server) |s| s.requestShutdown();
                        return @enumFromInt(1);
                    }
                    return @enumFromInt(0);
                }
            };
            _ = SetConsoleCtrlHandler(&handler_fn.callback, @enumFromInt(1));
        },
        else => {
            const handler_fn = struct {
                fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
                    _ = sig;
                    if (g_active_server) |s| s.requestShutdown();
                }
            };
            var act: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
            act.handler = .{ .handler = @ptrCast(&handler_fn.sigHandler) };
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
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Resolved event callback — null means silent (no events generated).
    event_callback: ?logging.ServerEventCallback = null,
    logged_stop: std.atomic.Value(bool) = .init(false),
    /// Live connections (keep-alive readers) so shutdown can wake them.
    conns_mu: sync.Spinlock = .{},
    active_conns: std.ArrayList(*tcp.Socket) = .empty,
    /// True while the run-thread sits inside accept(); shutdown waits for
    /// this before closing the listener (removes the close/enter race).
    in_accept: std.atomic.Value(bool) = .init(false),
    owns_io: bool = false,
    io_threaded: ?*std.Io.Threaded = null,
    paused: std.atomic.Value(bool) = .init(false),
    docs_mounted: bool = false,
    watcher: ?*watcher_mod.Watcher = null,
    live_reload_event_id: std.atomic.Value(u64) = .init(1),
    template_engine: ?*templates_mod.Engine = null,
    tls_server: ?tcp_tls_mod.TlsServer = null,
    tls_cert_pem_loaded: ?[]const u8 = null,
    tls_key_pem_loaded: ?[]const u8 = null,
    metrics_registry: metrics_mod.Registry = .{},
    start_time_ms: i64 = 0,

    /// Initializes server with explicit allocator, shared IO, and configuration.
    /// Matches `var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });`
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        return initInternal(allocator, io, false, null, cfg);
    }

    fn initInternal(
        allocator: Allocator,
        io: std.Io,
        owns_io: bool,
        io_threaded: ?*std.Io.Threaded,
        cfg: Config,
    ) !Server {
        const address_mod = @import("../net/address.zig");
        errdefer if (owns_io) {
            if (io_threaded) |th| {
                th.deinit();
                allocator.destroy(th);
            }
        };

        // Default: all-interfaces IPv4. Explicit literals (incl. "::") bind
        // their family; anything unparsable falls back to 0.0.0.0.
        var addr: address_mod.Address = blk: {
            if (std.mem.eql(u8, cfg.host, "0.0.0.0")) break :blk address_mod.Address.unspecified4(cfg.port);
            if (std.mem.eql(u8, cfg.host, "::")) break :blk address_mod.Address.unspecified6(cfg.port);
            var tmp: address_mod.Address = undefined;
            break :blk tmp.parseIp(cfg.host) catch address_mod.Address.unspecified4(cfg.port);
        };
        addr.port = cfg.port;

        // Resolve the event callback from config (null = silent, no events).
        // HTTPX never creates a writer or allocates IO resources for logging.

        var listener: tcp.Listener = undefined;
        if (cfg.port == 0) {
            listener = try tcp.Listener.bindAddress(io, &addr);
        } else {
            var current_port = cfg.port;
            var bound = false;
            const max_attempts = if (cfg.port_strategy == .incremental) cfg.max_port_attempts else 1;
            var attempt: u16 = 0;
            while (attempt < max_attempts) : (attempt += 1) {
                addr.port = current_port;
                if (tcp.Listener.bindAddress(io, &addr)) |l| {
                    listener = l;
                    bound = true;
                    break;
                } else |err| {
                    if (attempt + 1 >= max_attempts or cfg.port_strategy != .incremental) {
                        return err;
                    }
                    current_port +%= 1;
                }
            }
            if (!bound) return error.AddressInUse;
        }

        var effective_cfg = cfg;
        if (cfg.httpVersion) |v| {
            switch (v) {
                .auto => {},
                .http10 => {
                    effective_cfg.http10 = true;
                    effective_cfg.http11 = false;
                    effective_cfg.http2 = false;
                    effective_cfg.http3 = false;
                },
                .http11 => {
                    effective_cfg.http10 = false;
                    effective_cfg.http11 = true;
                    effective_cfg.http2 = false;
                    effective_cfg.http3 = false;
                },
                .http2 => {
                    effective_cfg.http10 = false;
                    effective_cfg.http11 = false;
                    effective_cfg.http2 = true;
                    effective_cfg.http3 = false;
                },
                .http3 => {
                    effective_cfg.http10 = false;
                    effective_cfg.http11 = false;
                    effective_cfg.http2 = false;
                    effective_cfg.http3 = true;
                },
            }
        }

        var template_engine: ?*templates_mod.Engine = null;
        const should_init_templates = if (effective_cfg.templates) |tc| tc.enabled else blk: {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, "templates", .{}) catch break :blk false;
            dir.close(io);
            break :blk true;
        };

        if (should_init_templates) {
            const t_cfg = effective_cfg.templates orelse templates_mod.Config{};
            const eng = try allocator.create(templates_mod.Engine);
            errdefer allocator.destroy(eng);
            eng.* = try templates_mod.Engine.init(allocator, io, t_cfg);
            template_engine = eng;
        }

        var tls_server_opt: ?tcp_tls_mod.TlsServer = null;
        var loaded_cert_pem: ?[]const u8 = null;
        var loaded_key_pem: ?[]const u8 = null;

        if (effective_cfg.tls) |*t_cfg| {
            t_cfg.allocator = allocator;
            const cert_opt = t_cfg.certificate orelse t_cfg.cert_pem;
            const key_opt = t_cfg.private_key orelse t_cfg.key_pem;
            if (cert_opt) |cert| {
                if (key_opt) |key| {
                    if (!t_cfg.hasIdentity()) {
                        t_cfg.loadCertificates(cert, key) catch {};
                    }
                    if (std.mem.indexOf(u8, cert, "-----BEGIN") != null) {
                        loaded_cert_pem = allocator.dupe(u8, cert) catch null;
                    } else {
                        loaded_cert_pem = tls_config_mod.readFileAlloc(allocator, cert, 10 * 1024 * 1024) catch null;
                    }
                    if (std.mem.indexOf(u8, key, "-----BEGIN") != null) {
                        loaded_key_pem = allocator.dupe(u8, key) catch null;
                    } else {
                        loaded_key_pem = tls_config_mod.readFileAlloc(allocator, key, 10 * 1024 * 1024) catch null;
                    }
                    if (loaded_cert_pem != null and loaded_key_pem != null) {
                        tls_server_opt = tcp_tls_mod.TlsServer.init(.{
                            .allocator = allocator,
                            .default_identity = .{
                                .cert_chain_pem = loaded_cert_pem.?,
                                .private_key_pem = loaded_key_pem.?,
                            },
                            .alpn_protocols = t_cfg.alpn_protocols,
                        });
                    }
                }
            }
        }

        var srv = Server{
            .io = io,
            .allocator = allocator,
            .listener = listener,
            .router = Router.init(allocator),
            .cfg = effective_cfg,
            .event_callback = cfg.logging.callback,
            .owns_io = owns_io,
            .io_threaded = io_threaded,
            .template_engine = template_engine,
            .tls_server = tls_server_opt,
            .tls_cert_pem_loaded = loaded_cert_pem,
            .tls_key_pem_loaded = loaded_key_pem,
            .start_time_ms = clock.millisNow(),
        };
        srv.router.template_engine = template_engine;
        errdefer {
            srv.router.deinit();
            if (template_engine) |eng| {
                eng.deinit();
                allocator.destroy(eng);
            }
            if (loaded_cert_pem) |c| allocator.free(c);
            if (loaded_key_pem) |k| {
                std.crypto.secureZero(u8, @constCast(k));
                allocator.free(k);
            }
        }

        return srv;
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.get(path, handler);
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.post(path, handler);
    }

    pub fn put(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.put(path, handler);
    }

    pub fn patch(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.patch(path, handler);
    }

    pub fn delete(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.delete(path, handler);
    }

    pub fn head(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.head(path, handler);
    }

    pub fn options(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.options(path, handler);
    }

    /// Registers a route with an arbitrary HTTP method.
    pub fn add(self: *Server, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response) router_mod.RouteError!void {
        try self.router.add(method, path, handler);
    }

    /// Attaches a global middleware to the server's routing pipeline.
    pub fn use(self: *Server, mw: router_mod.MiddlewareFn) !void {
        try self.router.use(mw);
    }

    /// Mounts a directory of static files under a URL prefix.
    pub fn static(self: *Server, mount_path: []const u8, dir_path: []const u8) !void {
        const static_mod = @import("../web/static_files/serve.zig");
        try static_mod.register(&self.router, .{
            .mount = mount_path,
            .root = dir_path,
        });
    }

    /// Mounts a Single Page Application (SPA) with index fallback.
    pub fn spa(self: *Server, mount_path: []const u8, dir_path: []const u8) !void {
        const spa_mod = @import("../web/spa/serve.zig");
        try spa_mod.register(&self.router, .{
            .mount = mount_path,
            .root = dir_path,
        });
    }

    /// Registers a Prometheus metrics exposition endpoint on the specified route.
    pub fn metrics(self: *Server, path: []const u8) router_mod.RouteError!void {
        const MetricsHandler = struct {
            fn handle(ctx: *Context) anyerror!Response {
                const reg: *metrics_mod.Registry = @ptrCast(@alignCast(ctx.user_data orelse return error.NoMetricsRegistry));
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
        try self.router.getWithData(path, MetricsHandler.handle, &self.metrics_registry);
    }

    /// Captures a point-in-time snapshot of the server metrics registry.
    pub fn metricsSnapshot(self: *const Server) metrics_mod.MetricsSnapshot {
        return self.metrics_registry.snapshot();
    }

    /// Captures a comprehensive runtime snapshot of the server (uptime, throughput, error rate, active connections).
    pub fn snapshot(self: *const Server) metrics_mod.ServerSnapshot {
        const now = clock.millisNow();
        const uptime: u64 = if (self.start_time_ms > 0 and now >= self.start_time_ms)
            @intCast(now - self.start_time_ms)
        else
            0;
        const ms = self.metrics_registry.snapshot();
        const uptime_sec = @as(f64, @floatFromInt(uptime)) / 1000.0;
        const rps = if (uptime_sec > 0.0) @as(f64, @floatFromInt(ms.requests_total)) / uptime_sec else 0.0;
        return .{
            .uptime_ms = uptime,
            .active_connections = ms.active_connections,
            .active_requests = ms.active_requests,
            .requests_total = ms.requests_total,
            .responses_total = ms.responses_total,
            .errors_total = ms.errors_total,
            .bytes_in = ms.bytes_in,
            .bytes_out = ms.bytes_out,
            .error_rate = ms.errorRate(),
            .requests_per_second = rps,
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
    pub fn setStatusHandler(self: *Server, status_code: u16, handler: *const fn (*Context) anyerror!Response) !void {
        try self.router.setStatusHandler(status_code, handler);
    }

    pub fn deinit(self: *Server) void {
        if (self.watcher) |w| {
            w.stop();
            w.deinit();
            self.watcher = null;
        }
        if (self.template_engine) |eng| {
            eng.deinit();
            self.allocator.destroy(eng);
            self.template_engine = null;
        }
        if (self.tls_cert_pem_loaded) |c| {
            self.allocator.free(c);
            self.tls_cert_pem_loaded = null;
        }
        if (self.tls_key_pem_loaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
            self.tls_key_pem_loaded = null;
        }
        if (self.cfg.tls) |*t| t.deinit();
        if (self.cfg.enableDocs) docs.unmount();
        self.router.deinit();
        self.listener.close(self.io);
        self.active_conns.deinit(self.allocator);
        if (self.owns_io) {
            if (self.io_threaded) |th| {
                th.deinit();
                self.allocator.destroy(th);
                self.io_threaded = null;
            }
        }
    }

    /// Returns true if this server has TLS configured and active.
    pub fn isTls(self: *const Server) bool {
        return self.tls_server != null;
    }

    /// Dynamically sets or updates TLS certificates on this server instance.
    pub fn setTls(self: *Server, cert_pem_or_path: []const u8, key_pem_or_path: []const u8) !void {
        if (self.tls_cert_pem_loaded) |c| self.allocator.free(c);
        if (self.tls_key_pem_loaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
            self.tls_key_pem_loaded = null;
        }
        var cert_str: []u8 = undefined;
        if (std.mem.indexOf(u8, cert_pem_or_path, "-----BEGIN") != null) {
            cert_str = try self.allocator.dupe(u8, cert_pem_or_path);
        } else {
            cert_str = try tls_config_mod.readFileAlloc(self.allocator, cert_pem_or_path, 10 * 1024 * 1024);
        }
        errdefer self.allocator.free(cert_str);

        var key_str: []u8 = undefined;
        if (std.mem.indexOf(u8, key_pem_or_path, "-----BEGIN") != null) {
            key_str = try self.allocator.dupe(u8, key_pem_or_path);
        } else {
            key_str = try tls_config_mod.readFileAlloc(self.allocator, key_pem_or_path, 10 * 1024 * 1024);
        }
        errdefer {
            std.crypto.secureZero(u8, key_str);
            self.allocator.free(key_str);
        }

        self.tls_cert_pem_loaded = cert_str;
        self.tls_key_pem_loaded = key_str;

        self.tls_server = tcp_tls_mod.TlsServer.init(.{
            .allocator = self.allocator,
            .default_identity = .{
                .cert_chain_pem = cert_str,
                .private_key_pem = key_str,
            },
            .alpn_protocols = if (self.cfg.tls) |t| t.alpn_protocols else &alpn_mod.DEFAULT_TCP_PREFERENCE,
        });
    }

    /// Returns the active template engine, if templates are enabled.
    pub fn templates(self: *Server) ?*templates_mod.Engine {
        return self.template_engine;
    }

    pub fn localPort(self: *const Server) u16 {
        return self.listener.localPort();
    }

    /// Signals the accept loop to stop and wakes a blocked accept() by
    /// closing the listening socket (POSIX) or connecting a dummy socket (Windows).
    /// Safe to call multiple times.
    pub fn requestShutdown(self: *Server) void {
        if (!self.logged_stop.swap(true, .acq_rel)) {
            self.emit(.{ .kind = .server_stopped, .level = .info, .message = "shutting down" });
        }
        self.stop_flag.store(true, .release);

        // On Windows (Zig 0.16), the AFD-backed listener uses IOCP for accept().
        // Closing the listening socket while a thread is blocked in netAcceptWindows
        // returns STATUS_CANCELLED, which the stdlib marks `unreachable` → panic.
        // tcp.wakeListenerPort() connects a dummy socket to the port instead,
        // waking accept() naturally. The accept loop then sees stop==true and exits.
        // On POSIX, wakeListenerPort is a no-op and we close the listener directly.
        if (self.in_accept.load(.acquire)) {
            tcp.wakeListenerPort(self.listener.localPort());
        }
        if (@import("builtin").os.tag != .windows) {
            self.listener.close(self.io);
        }

        // A keep-alive worker may be blocked in recv() and therefore never
        // reach accept(). Wake those readers immediately; Socket.close is
        // idempotent and the worker's deferred close will observe the same close flag.
        self.conns_mu.lock();
        for (self.active_conns.items) |conn| conn.close();
        self.conns_mu.unlock();
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
        if (self.in_accept.load(.acquire)) {
            tcp.wakeListenerPort(self.listener.localPort());
        }
    }

    /// Return the full bound address. Supports IPv4 and IPv6.
    pub fn localAddress(self: *const Server) std.Io.net.IpAddress {
        return self.listener.server.socket.address;
    }

    /// Blocking accept loop. `requestShutdown()` takes effect between
    /// accepts; `max_connections` (when nonzero) makes run() return after
    /// that many connections, which is how tests join deterministically.
    /// Installs a Ctrl+C handler for graceful shutdown.
    pub fn run(self: *Server) void {
        // Mount docs here (not in init) because init returns by value,
        // making any &srv.router pointer taken inside init a dangling pointer.
        if (self.cfg.enableDocs and !self.docs_mounted) {
            self.docs_mounted = true;
            const dc = self.cfg.docs orelse docs.Config{};
            docs.mount(self.allocator, &self.router, dc, .{
                .title = self.cfg.docs_title,
                .version = @import("../common/version.zig").version,
            }) catch {};
        }

        // Out-of-the-box watcher and live-reload integration
        if ((self.cfg.watch or self.cfg.live_reload) and self.watcher == null) {
            const WatcherCallback = struct {
                fn onChange(event: watcher_mod.WatchEvent, user_data: ?*anyopaque) void {
                    const s: *Server = @ptrCast(@alignCast(user_data.?));
                    _ = s.live_reload_event_id.fetchAdd(1, .release);
                    if (s.template_engine) |te| {
                        te.invalidate(event.path);
                    }
                    s.emit(.{
                        .kind = .server_started,
                        .level = .debug,
                        .path = event.path,
                        .message = switch (event.strategy) {
                            .hot_reload => "file changed: hot reload CSS",
                            .warm_reload => "file changed: warm reload HTML",
                            .cold_reload => "file changed: cold reload assets/config",
                            .restart => "file changed: application source modified",
                        },
                    });
                }
            };

            const w = watcher_mod.Watcher.init(self.allocator, self.io, .{
                .dir_path = self.cfg.watch_dir,
                .on_change = WatcherCallback.onChange,
                .user_data = self,
            }) catch null;
            if (w) |initialized_w| {
                self.watcher = initialized_w;
                initialized_w.start() catch {};
            }

            if (self.cfg.live_reload) {
                const SseHandler = struct {
                    fn handle(ctx: *Context) anyerror!Response {
                        const s: *Server = @ptrCast(@alignCast(ctx.user_data.?));
                        const current_id = s.live_reload_event_id.load(.acquire);
                        const sse_body = try std.fmt.allocPrint(ctx.allocator, "id: {d}\ndata: reload\n\n", .{current_id});
                        return .{
                            .status = 200,
                            .body = sse_body,
                            .headers = &.{
                                .{ .name = "Content-Type", .value = "text/event-stream" },
                                .{ .name = "Cache-Control", .value = "no-cache" },
                                .{ .name = "Connection", .value = "keep-alive" },
                            },
                        };
                    }
                };
                self.router.getWithData(self.cfg.live_reload_path, SseHandler.handle, self) catch {};
            }
        }

        installShutdownHandler(self);
        self.emit(.{
            .kind = .server_started,
            .level = .info,
            .path = self.cfg.host,
            .status = self.listener.localPort(),
            .message = "server started",
        });
        var served: usize = 0;
        while (!self.stop_flag.load(.acquire)) {
            if (self.cfg.max_connections != 0 and served >= self.cfg.max_connections) break;
            // Yield when paused
            while (self.paused.load(.acquire) and !self.stop_flag.load(.acquire)) {
                clock.sleepMillis(10);
            }
            self.in_accept.store(true, .release);
            var conn = self.listener.accept(self.io) catch {
                self.in_accept.store(false, .release);
                break;
            };
            self.in_accept.store(false, .release);
            defer conn.close();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.serveConnection(&conn, arena.allocator()) catch {};
            served += 1;

            // Stop before blocking on the next accept when asked.
            if (self.stop_flag.load(.acquire)) break;
        }
        self.emit(.{ .kind = .server_stopped, .level = .info, .message = "shutdown complete" });
    }

    /// Deliver a structured event to the application callback.
    /// No-op when callback is null (the default). Level filtering applied here.
    fn emit(self: *const Server, event: logging.ServerEvent) void {
        const cb = self.event_callback orelse return;
        if (@intFromEnum(event.level) < @intFromEnum(self.cfg.logging.level)) return;
        cb(event);
    }

    fn serveConnection(self: *Server, conn: *tcp.Socket, arena_in: Allocator) !void {
        _ = arena_in;
        self.metrics_registry.connectionOpened();
        defer self.metrics_registry.connectionClosed();

        // Peek or read initial bytes to check protocol / TLS / HTTP/2 preface
        var peek_buf: [32]u8 = undefined;
        const n_peek = conn.read(peek_buf[0..]) catch return;
        if (n_peek == 0) return;

        // Check for TLS Handshake record (ContentType = 0x16, TLS legacy version 0x03, 0x01..0x03)
        if (self.tls_server != null) {
            if (n_peek >= 3 and peek_buf[0] == 0x16 and peek_buf[1] == 0x03) {
                var tls_conn = self.tls_server.?.handshakeBuffered(conn, peek_buf[0..n_peek]) catch {
                    self.emit(.{ .kind = .tls_handshake_failed, .level = .warn, .message = "TLS handshake failed" });
                    return;
                };
                defer tls_conn.deinit();

                const stream_conn = StreamConn{ .tls = &tls_conn };
                if (self.cfg.http2 and tls_conn.alpn == .h2) {
                    try self.serveHttp2Connection(stream_conn, true, "");
                } else {
                    try self.serveHttp1Connection(stream_conn, true, "");
                }
                return;
            } else if (self.cfg.tls == null or !self.cfg.tls.?.allow_plain_http) {
                // Strict HTTPS mode: reject cleartext HTTP on HTTPS port (RFC 9110)
                const plain_conn = StreamConn{ .plain = conn };
                _ = sendSimpleError(plain_conn, 400, "The plain HTTP request was sent to HTTPS port") catch 0;
                return;
            }
        }

        const h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        if (self.cfg.http2 and n_peek >= 16 and std.mem.startsWith(u8, peek_buf[0..n_peek], h2_preface[0..16])) {
            const stream_conn = StreamConn{ .plain = conn };
            try self.serveHttp2Connection(stream_conn, false, peek_buf[0..n_peek]);
            return;
        }

        const stream_conn = StreamConn{ .plain = conn };
        try self.serveHttp1Connection(stream_conn, false, peek_buf[0..n_peek]);
    }

    fn serveHttp2Connection(self: *Server, conn: StreamConn, is_tls: bool, initial: []const u8) !void {
        const H2Bridge = struct {
            fn handle(ctx_ptr: ?*anyopaque, is_tls_flag: bool, m_str: []const u8, p_str: []const u8, hdrs: []const @import("../protocols/http2/transport.zig").Header, b_str: []const u8) anyerror!@import("../protocols/http2/transport.zig").HandlerResponse {
                const server_ptr: *Server = @ptrCast(@alignCast(ctx_ptr.?));
                const method = Method.fromString(m_str) orelse .GET;
                var arena_h2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena_h2.deinit();
                const a = arena_h2.allocator();

                var ctx_hdrs = try a.alloc(router_mod.Header, hdrs.len);
                for (hdrs, 0..) |h, i| ctx_hdrs[i] = .{ .name = h.name, .value = h.value };

                var clean_path = p_str;
                if (std.mem.indexOfAny(u8, clean_path, "?#")) |idx| {
                    clean_path = clean_path[0..idx];
                }

                var ctx = Context{
                    .allocator = a,
                    .io = server_ptr.io,
                    .headers = ctx_hdrs,
                    .path = clean_path,
                    .method = method,
                    .body = b_str,
                    .is_tls = is_tls_flag,
                    .trust_forwarded = server_ptr.cfg.trust_forwarded_headers,
                };

                const handler = server_ptr.router.match(method, clean_path, &ctx) orelse {
                    return .{ .status = 404, .body = "not found" };
                };
                const res = handler(&ctx) catch {
                    return .{ .status = 500, .body = "internal server error" };
                };
                return .{
                    .status = res.status,
                    .body = res.body,
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

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const transport_mod = @import("../protocols/http2/transport.zig");

        // ServerCtx accumulates streams
        var sc = struct {
            arena: Allocator,
            sid: u31 = 0,
            method: std.ArrayList(u8) = .empty,
            path: std.ArrayList(u8) = .empty,
            hdrs: std.ArrayList(transport_mod.Header) = .empty,
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

            fn onHeaders(ctx_p: ?*anyopaque, sid: u31, flds: []@import("../protocols/http2/hpack.zig").HeaderField, end_stream: bool) anyerror!void {
                const s: *@This() = @ptrCast(@alignCast(ctx_p.?));
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
                if (end_stream) s.dispatched = true;
            }

            fn onData(ctx_p: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
                const s: *@This() = @ptrCast(@alignCast(ctx_p.?));
                if (sid != s.sid) return;
                try s.body.appendSlice(s.arena, data);
            }
        }{ .arena = arena_state.allocator() };

        session.cbs = .{
            .ctx = &sc,
            .onHeaders = @TypeOf(sc).onHeaders,
            .onData = @TypeOf(sc).onData,
        };

        var buf: [16 * 1024]u8 = undefined;
        while (!session.closed and !session.goaway_received) {
            if (session.outbound.items.len > 0) {
                conn.writeAll(session.outbound.items) catch break;
                session.outbound.clearRetainingCapacity();
            }
            if (sc.dispatched and !sc.responded) {
                sc.responded = true;
                const resp = H2Bridge.handle(self, is_tls, sc.method.items, sc.path.items, sc.hdrs.items, sc.body.items) catch transport_mod.HandlerResponse{ .status = 500 };

                var out_fields = std.ArrayList(@import("../protocols/http2/hpack.zig").HeaderField).empty;
                defer out_fields.deinit(self.allocator);
                var st_buf: [8]u8 = undefined;
                var cl_buf: [8]u8 = undefined;
                const st = std.fmt.bufPrint(&st_buf, "{d}", .{resp.status}) catch "500";
                const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{resp.body.len}) catch "0";
                try out_fields.append(self.allocator, .{ .name = ":status", .value = st });
                try out_fields.append(self.allocator, .{ .name = "content-length", .value = cl });
                for (resp.headers) |h| {
                    try out_fields.append(self.allocator, .{ .name = h.name, .value = h.value });
                }

                try session.sendHeaders(sc.sid, out_fields.items, resp.body.len == 0);
                if (resp.body.len > 0) {
                    _ = try session.sendData(sc.sid, resp.body, true);
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

    fn serveHttp1Connection(self: *Server, conn: StreamConn, is_tls: bool, initial: []const u8) !void {
        if (!self.cfg.keep_alive) {
            var arena_one = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_one.deinit();
            _ = try self.serveOneRequestBuffered(conn, arena_one.allocator(), 0, true, initial, is_tls);
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

        self.conns_mu.lock();
        self.active_conns.append(self.allocator, sock) catch |err| {
            self.conns_mu.unlock();
            return err;
        };
        self.conns_mu.unlock();
        defer {
            self.conns_mu.lock();
            for (self.active_conns.items, 0..) |sc, i| {
                if (sc == sock) {
                    _ = self.active_conns.swapRemove(i);
                    break;
                }
            }
            self.conns_mu.unlock();
        }

        var served_n: usize = 0;
        while (served_n < self.cfg.max_requests_per_conn) : (served_n += 1) {
            _ = arena.reset(.retain_capacity);
            const init_bytes = if (served_n == 0) initial else "";
            const want_more = self.serveOneRequestBuffered(conn, arena.allocator(), served_n, false, init_bytes, is_tls) catch return;
            if (!want_more) break;
        }
    }

    fn serveOneRequest(self: *Server, conn: StreamConn, arena: Allocator, idx: usize, force_close: bool, is_tls: bool) !bool {
        return self.serveOneRequestBuffered(conn, arena, idx, force_close, "", is_tls);
    }

    fn serveOneRequestBuffered(self: *Server, conn: StreamConn, arena: Allocator, _: usize, force_close: bool, initial: []const u8, is_tls: bool) !bool {
        const t0 = clock.millisNow();
        self.metrics_registry.recordRequest();
        var head_buf: [max_head_bytes]u8 = undefined;
        var filled: usize = 0;
        if (initial.len > 0) {
            const take = @min(initial.len, head_buf.len);
            @memcpy(head_buf[0..take], initial[0..take]);
            filled = take;
        }
        const allow_lf = self.cfg.allow_lf_line_endings;
        while (filled < head_buf.len) {
            if (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") != null) break;
            if (allow_lf and std.mem.indexOf(u8, head_buf[0..filled], "\n\n") != null) {
                // Ensure not just \r\n\r\n already handled; check bare LF
                var has_bare = false;
                for (head_buf[0..filled], 0..) |c, i| {
                    if (c == '\n' and i > 0 and head_buf[i - 1] != '\r') {
                        // Check if previous char before \n\n is not \r
                        if (i + 1 < filled and head_buf[i + 1] == '\n') has_bare = true;
                    }
                }
                if (has_bare) break;
                if (std.mem.indexOf(u8, head_buf[0..filled], "\n\n") != null) break;
            }
            const n = conn.read(head_buf[filled..]) catch return false;
            if (n == 0) return false; // peer closed
            filled += n;
        }
        self.metrics_registry.recordBytesIn(filled);

        const parser_opts: parser_mod.Options = .{ .allow_lf_line_endings = allow_lf };
        const req_head = parser_mod.parseRequestHeadWithOptions(head_buf[0..filled], parser_opts) catch {
            self.metrics_registry.recordError();
            _ = sendSimpleError(conn, 400, "bad request") catch 0;
            return false;
        };

        self.metrics_registry.recordRequestMethod(req_head.method);

        if (req_head.minor_version == 0 and !self.cfg.http10) {
            _ = sendSimpleError(conn, 505, "HTTP/1.0 Not Supported") catch 0;
            return false;
        }
        if (req_head.minor_version == 1 and !self.cfg.http11) {
            _ = sendSimpleError(conn, 505, "HTTP/1.1 Not Supported") catch 0;
            return false;
        }

        // Headers -> Context slice.
        var fields: [parser_mod.DEFAULT_MAX_HEADERS]parser_mod.Field = undefined;
        const blk = parser_mod.parseHeaderBlockWithOptions(head_buf[0..filled], req_head.head_end, fields[0..], parser_opts) catch {
            _ = sendSimpleError(conn, 400, "bad headers") catch 0;
            return false;
        };

        const hdrs = arena.alloc(router_mod.Header, blk.count) catch return false;
        for (fields[0..blk.count], 0..) |f, i| hdrs[i] = .{ .name = f.name, .value = f.value };

        // Connection reuse decision (RFC 9112 Section 7): explicit "close" wins;
        // HTTP/1.0 defaults to close unless it requested keep-alive.
        var client_close = force_close or req_head.minor_version == 0;
        var client_ka10 = false;
        for (hdrs) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            if (std.ascii.indexOfIgnoreCase(h.value, "close") != null) client_close = true;
            if (std.ascii.indexOfIgnoreCase(h.value, "keep-alive") != null) client_ka10 = true;
        }
        if (req_head.minor_version == 0 and client_ka10) client_close = false;

        // Body: Content-Length or chunked (both bounded by cfg.max_body).
        var body: []u8 = "";
        const framing = parser_mod.decideFraming(fields[0..blk.count], false, 0, 0) catch {
            _ = sendSimpleError(conn, 400, "invalid message framing") catch 0;
            return false;
        };
        var has_expect = false;
        for (fields[0..blk.count]) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "expect")) {
                has_expect = true;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field.value, " \t"), "100-continue")) {
                    _ = sendSimpleError(conn, 417, "expectation failed") catch 0;
                    return false;
                }
            }
        }
        if (has_expect and req_head.minor_version == 1 and framing.framing != .none) {
            const interim = writer_mod.buildInformational(arena, 100, &.{}) catch return false;
            defer arena.free(interim);
            conn.writeAll(interim) catch return false;
        }
        {
            const fr = framing;
            switch (fr.framing) {
                .none, .content_length => {
                    if (fr.length > self.cfg.max_body) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = arena.alloc(u8, fr.length) catch return false;
                    // How many body bytes were already pulled in by the header reads.
                    const buffered = if (filled > blk.end) filled - blk.end else 0;
                    if (buffered > fr.length) client_close = true;
                    const take = @min(buffered, fr.length);
                    @memcpy(body[0..take], head_buf[blk.end..][0..take]);
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
                    var dec: parser_mod.ChunkedDecoder = .{};
                    var acc: std.ArrayList(u8) = .empty;
                    var raw: std.ArrayList(u8) = .empty;
                    raw.appendSlice(arena, head_buf[blk.end..filled]) catch return false;
                    var unparsed: usize = 0;
                    while (true) {
                        const tail = dec.decode(raw.items[unparsed..]) catch |e| switch (e) {
                            error.Incomplete => {
                                const n = conn.read(head_buf[0..]) catch return false;
                                if (n == 0) return false;
                                raw.appendSlice(arena, head_buf[0..n]) catch return false;
                                continue;
                            },
                            else => return false,
                        };
                        const produced = raw.items.len - unparsed - tail;
                        acc.appendSlice(arena, raw.items[unparsed..][0..produced]) catch return false;
                        unparsed += produced;
                        if (dec.state == .done) break;
                        const n = conn.read(head_buf[0..]) catch return false;
                        if (n == 0) return false;
                        raw.appendSlice(arena, head_buf[0..n]) catch return false;
                    }
                    // Any bytes after the terminating chunk are currently not
                    // retained for the next request, so do not reuse this
                    // connection when the read crossed message boundaries.
                    if (unparsed < raw.items.len) client_close = true;
                    if (acc.items.len > self.cfg.max_body) {
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

        const method = Method.fromString(req_head.method) orelse {
            _ = sendSimpleError(conn, 501, "method not supported") catch 0;
            return false;
        };

        const is_head = method == .HEAD;

        const raw_path = req_head.path;
        var clean_path = raw_path;
        if (std.mem.indexOfAny(u8, clean_path, "?#")) |idx| {
            clean_path = clean_path[0..idx];
        }

        var ctx = Context{
            .allocator = arena,
            .io = self.io,
            .headers = hdrs,
            .path = clean_path,
            .method = method,
            .body = body,
            .is_tls = is_tls,
            .trust_forwarded = self.cfg.trust_forwarded_headers,
        };
        const res: Response = self.router.dispatch(&ctx);

        const bytes_out = writeResponse(conn, arena, req_head.minor_version, res, is_head, if (client_close) "close" else "keep-alive", ctx.header("Accept-Encoding")) catch {
            self.metrics_registry.recordError();
            return false;
        };
        const dur_ns: u64 = @intCast(@max(0, (clock.millisNow() -| t0) * 1_000_000));
        self.metrics_registry.recordResponseFull(res.status, dur_ns, bytes_out);
        self.emitAccess(req_head.method, req_head.path, res.status, body.len, bytes_out, t0);
        return !client_close;
    }

    /// Deliver a request_completed event to the application callback.
    /// Secrets never appear here: only method/path/status/timing/byte counts.
    fn emitAccess(self: *Server, method: []const u8, path: []const u8, status: u16, bytes_in: usize, bytes_out: usize, t0: i64) void {
        const dur = clock.millisNow() -| t0;
        self.emit(.{
            .kind = .request_completed,
            .level = .info,
            .method = method,
            .path = path,
            .status = status,
            .duration_ms = dur,
            .bytes_in = bytes_in,
            .bytes_out = bytes_out,
        });
    }

    fn writeResponse(conn: StreamConn, arena: Allocator, minor: u8, res: Response, is_head: bool, conn_hdr: []const u8, accept_encoding: ?[]const u8) !usize {
        // conn_hdr selects the Connection header emitted ("" -> legacy close).
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);

        lines.append(arena, if (conn_hdr.len > 0)
            (std.fmt.allocPrint(arena, "Connection: {s}", .{conn_hdr}) catch return 0)
        else
            "Connection: close") catch return 0;

        if (res.content_type) |ct| {
            const line = std.fmt.allocPrint(arena, "Content-Type: {s}", .{ct}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        for (res.headers) |h| {
            const line = std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }) catch return 0;
            lines.append(arena, line) catch return 0;
        }

        var encoded_body: ?[]u8 = null;
        defer if (encoded_body) |b| arena.free(b);
        var body_out: []const u8 = if (is_head) "" else res.body;
        var content_encoding: ?[]const u8 = null;
        const is_huge_asset = res.body.len > 128 * 1024;
        if (!is_head and !is_huge_asset and res.body.len > 0 and res.status != 204 and res.status != 304 and accept_encoding != null) {
            const selected = compression.negotiate(accept_encoding.?);
            if (selected != .identity) {
                encoded_body = compression.compress(arena, selected, res.body) catch null;
                if (encoded_body) |b| {
                    body_out = b;
                    content_encoding = selected.token();
                }
            }
        }
        if (content_encoding) |ce| {
            lines.append(arena, "Vary: Accept-Encoding") catch return 0;
            const line = std.fmt.allocPrint(arena, "Content-Encoding: {s}", .{ce}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        const reason: []const u8 = if (writer_mod.reasonPhrase(res.status).len > 0)
            writer_mod.reasonPhrase(res.status)
        else
            reasonFor(res.status);
        var resp_headers = try arena.alloc(writer_mod.Header, lines.items.len);
        for (lines.items, 0..) |line, i| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
            resp_headers[i] = .{
                .name = std.mem.trim(u8, line[0..colon], " "),
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            };
        }
        const raw = writer_mod.buildResponse(
            arena,
            res.status,
            reason,
            body_out,
            .{ .minor_version = minor, .headers = resp_headers },
            is_head,
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
        return .{ .body = "hi", .content_type = "text/plain" };
    }
    return .{ .status = 404, .body = "" };
}

test "server handles POST with content-length body" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .max_connections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.post("/echo", echoRawHandler);

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
    var req_buf: [256]u8 = undefined;
    const raw = try std.fmt.bufPrint(&req_buf, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
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
    return .{ .content_type = "application/json", .body = ctx.body };
}

// Logging verification: callback receives access events; silence when no callback.

const sync = @import("../common/sync.zig");

// Thread-local capture for test callbacks (single-threaded test context).
var g_capture_seen: usize = 0;
var g_capture_got_request: bool = false;
var g_capture_got_lifecycle: bool = false;
var g_capture_mu: sync.Spinlock = .{};

fn testEventCallback(event: logging.ServerEvent) void {
    g_capture_mu.lock();
    defer g_capture_mu.unlock();
    g_capture_seen += 1;
    if (event.kind == .request_completed and
        std.mem.indexOf(u8, event.path, "/logged") != null and
        std.mem.eql(u8, event.method, "GET"))
        g_capture_got_request = true;
    if (event.kind == .server_started or event.kind == .server_stopped)
        g_capture_got_lifecycle = true;
}

test "access log flows through event callback" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture state.
    g_capture_seen = 0;
    g_capture_got_request = false;
    g_capture_got_lifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
        .logging = .{ .callback = testEventCallback },
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk);

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

    // max_connections=1 => run() returns only AFTER emitAccess ran.
    t.join();
    srv.requestShutdown();
    try std.testing.expect(g_capture_got_request);
    try std.testing.expect(g_capture_got_lifecycle);
}

test "no callback produces zero events" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture (should stay zero without callback).
    g_capture_seen = 0;
    g_capture_got_request = false;
    g_capture_got_lifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
        .logging = .{}, // null callback — silent by default
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk);

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
    try std.testing.expectEqual(@as(usize, 0), g_capture_seen);
}

fn returnOk(_: *Context) anyerror!Response {
    return .{ .body = "ok", .content_type = "text/plain" };
}

test "server serves routed GET end to end" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .max_connections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.get("/hello", helloHandler);

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
    var srv = Server.init(a, ctx0.io, .{ .port = 0, .enableDocs = false, .max_connections = 1 }) catch return;
    defer srv.deinit();
    const LenH = struct {
        fn h(ctx: *Context) anyerror!Response {
            const t = std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.body.len}) catch return error.OutOfMemory;
            return .{ .body = t };
        }
    };
    try srv.router.post("/len", LenH.h);
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
        .max_connections = 1,
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
        .max_connections = 1,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(!srv.isTls());

    const cert1 = "-----BEGIN CERTIFICATE-----\nCERT1\n-----END CERTIFICATE-----\n";
    const key1 = "-----BEGIN PRIVATE KEY-----\nKEY1\n-----END PRIVATE KEY-----\n";
    try srv.setTls(cert1, key1);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert1, srv.tls_cert_pem_loaded.?);

    // Reconfigure dynamically with new cert/key
    const cert2 = "-----BEGIN CERTIFICATE-----\nCERT2\n-----END CERTIFICATE-----\n";
    const key2 = "-----BEGIN PRIVATE KEY-----\nKEY2\n-----END PRIVATE KEY-----\n";
    try srv.setTls(cert2, key2);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert2, srv.tls_cert_pem_loaded.?);
}

test "strict HTTPS mode rejects plain HTTP with 400 Bad Request" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
    }) catch return;
    defer srv.deinit();

    const cert = "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----\n";
    const key = "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n";
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

var g_tls_failed_seen: bool = false;
var g_tls_failed_mu: sync.Spinlock = .{};

fn testTlsEventCallback(event: logging.ServerEvent) void {
    if (event.kind == .tls_handshake_failed) {
        g_tls_failed_mu.lock();
        defer g_tls_failed_mu.unlock();
        g_tls_failed_seen = true;
    }
}

test "malformed TLS handshake emits tls_handshake_failed event" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    g_tls_failed_mu.lock();
    g_tls_failed_seen = false;
    g_tls_failed_mu.unlock();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
        .logging = .{ .callback = testTlsEventCallback, .level = .warn },
    }) catch return;
    defer srv.deinit();

    const cert = "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----\n";
    const key = "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n";
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
    const bad_tls = [_]u8{ 0x16, 0x03, 0x01, 0x00, 0x05, 0xde, 0xad, 0xbe, 0xef, 0x00 };
    try client.writeAll(&bad_tls);

    // Give server worker moment to process and emit event
    clock.sleepMillis(50);

    srv.requestShutdown();

    g_tls_failed_mu.lock();
    const seen = g_tls_failed_seen;
    g_tls_failed_mu.unlock();
    try std.testing.expect(seen);
}

test "StreamConn operations" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/stream", returnOk);

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

test "Context is_tls and scheme reflect connection security" {
    const a = std.testing.allocator;
    var ctx_plain = Context{
        .allocator = a,
        .is_tls = false,
    };
    try std.testing.expectEqualStrings("http", ctx_plain.scheme());

    var ctx_tls = Context{
        .allocator = a,
        .is_tls = true,
    };
    try std.testing.expectEqualStrings("https", ctx_tls.scheme());

    var hdrs: [1]router_mod.Header = .{.{ .name = "X-Forwarded-Proto", .value = "https" }};
    var ctx_forwarded = Context{
        .allocator = a,
        .is_tls = false,
        .trust_forwarded = true,
        .headers = &hdrs,
    };
    try std.testing.expectEqualStrings("https", ctx_forwarded.scheme());
}

test "server metrics snapshot and live Prometheus endpoint" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 2,
    }) catch return;
    defer srv.deinit();

    try srv.router.get("/hello", helloHandler);
    try srv.metrics("/metrics");

    const snap0 = srv.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), snap0.requests_total);

    const s_snap0 = srv.snapshot();
    try std.testing.expectEqual(@as(u64, 0), s_snap0.requests_total);

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
    try std.testing.expect(snap1.requests_total >= 2);
    try std.testing.expectEqual(@as(u64, 0), snap1.errors_total);

    const s_snap1 = srv.snapshot();
    try std.testing.expect(s_snap1.requests_total >= 2);
    try std.testing.expectEqual(@as(u64, 0), s_snap1.active_requests);
}
