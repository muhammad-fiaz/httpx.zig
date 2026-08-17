//! HTTP Server Implementation for httpx.zig
//!
//! Production-ready HTTP server with comprehensive features:
//!
//! - Pattern-based routing with path parameters
//! - Middleware stack support
//! - Context-based request handling
//! - JSON response helpers
//! - Static file serving
//! - Cross-platform (Linux, Windows, macOS)

const std = @import("std");
const tint = @import("tint");
const mem = std.mem;
const Allocator = mem.Allocator;
const net = @import("../net/compat.zig");

const types = @import("../core/types.zig");
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;
const ResponseBuilder = @import("../core/response.zig").ResponseBuilder;
const Headers = @import("../core/headers.zig").Headers;
const HeaderName = @import("../core/headers.zig").HeaderName;
const Parser = @import("../protocol/parser.zig").Parser;
const status_mod = @import("../core/status.zig");
const http = @import("../protocol/http.zig");
const hpack = @import("../protocol/hpack.zig");
const h2stream = @import("../protocol/stream.zig");
const qpack = @import("../protocol/qpack.zig");
const quic = @import("../protocol/quic.zig");
const Socket = @import("../net/socket.zig").Socket;
const TcpListener = @import("../net/socket.zig").TcpListener;
const UdpSocket = @import("../net/socket.zig").UdpSocket;
const tls_mod = @import("../tls/tls.zig");
const alpn = @import("../tls/alpn.zig");
const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;
const common = @import("../util/common.zig");
const list_writer = @import("../util/list_writer.zig");
const io_util = @import("../util/any_io.zig");
const Executor = @import("../concurrency/executor.zig").Executor;
const dbg = @import("../util/debug.zig");

const defaultIo = io_util.defaultIo;
const sleepMs = io_util.sleepMsI;

pub const CookieOptions = common.CookieOptions;
pub const SameSite = common.SameSite;

/// Strategy for handling bind conflicts on startup.
pub const PortConflictStrategy = enum {
    /// Fail immediately when the configured port is unavailable.
    fail,
    /// Retry on subsequent ports (`port + 1`, `port + 2`, ...) until a free port is found.
    increment,
};

pub const SseEvent = @import("../util/sse.zig").Event;

/// Pre-route hook called after parsing the request and before route matching.
pub const PreRouteHook = *const fn (*Context) anyerror!void;

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

pub const LogFn = *const fn (level: LogLevel, message: []const u8) void;

/// Server configuration.
pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    port_conflict: PortConflictStrategy = .fail,
    max_port_tries: u16 = 32,
    max_body_size: usize = 10 * 1024 * 1024,
    request_timeout_ms: u64 = 30_000,
    keep_alive_timeout_ms: u64 = 60_000,
    max_connections: u32 = 1000,
    keep_alive: bool = true,
    threads: u32 = 0,
    http2_enabled: bool = false,
    http3_enabled: bool = false,
    enable_push: bool = true,
    http2_settings: types.Http2Settings = .{},
    http3_settings: types.Http3Settings = .{},
    log_fn: ?LogFn = null,
    log_level: LogLevel = .info,
    unix_path: ?[]const u8 = null,
    tls_enabled: bool = false,
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    tls_alpn_protocols: []const []const u8 = &.{ "h3", "h2", "http/1.1" },
};

/// File-serving options used by `Context.fileWithOptions`.
pub const FileResponseOptions = struct {
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    add_etag: bool = true,
    add_nosniff: bool = true,
    conditional_get: bool = true,
};

/// Request context passed to handlers.
pub const Context = struct {
    allocator: Allocator,
    request: *Request,
    response: ResponseBuilder,
    params: std.StringHashMap([]const u8),
    data: std.StringHashMap(*anyopaque),
    server: ?*Server = null,

    const Self = @This();

    /// Creates a new context for a request.
    pub fn init(allocator: Allocator, req: *Request) Self {
        return .{
            .allocator = allocator,
            .request = req,
            .response = ResponseBuilder.init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .data = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    /// Releases context resources.
    pub fn deinit(self: *Self) void {
        self.response.deinit();
        self.params.deinit();
        self.data.deinit();
    }

    /// Returns a URL parameter by name.
    pub fn param(self: *const Self, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Returns a query parameter by name.
    pub fn query(self: *const Self, name: []const u8) ?[]const u8 {
        const query_str = self.request.uri.query orelse return null;
        return common.queryValue(query_str, name);
    }

    /// Returns a request header by name.
    pub fn header(self: *const Self, name: []const u8) ?[]const u8 {
        return self.request.headers.get(name);
    }

    /// Returns the raw Authorization header value.
    pub fn authorization(self: *const Self) ?[]const u8 {
        return self.request.headers.get(HeaderName.AUTHORIZATION);
    }

    /// Returns Bearer token bytes when Authorization is `Bearer <token>`.
    pub fn bearerToken(self: *const Self) ?[]const u8 {
        const raw = self.authorization() orelse return null;
        if (raw.len < 7) return null;
        if (!std.ascii.eqlIgnoreCase(raw[0..7], "Bearer ")) return null;
        return mem.trim(u8, raw[7..], " \t");
    }

    /// Returns true when request Content-Type matches the expected media type.
    pub fn hasContentType(self: *const Self, expected: []const u8) bool {
        return self.request.hasContentType(expected);
    }

    /// Returns true when request Content-Type is application/json.
    pub fn isJson(self: *const Self) bool {
        return self.request.isJsonContent();
    }

    /// Returns true when request Content-Type is application/x-www-form-urlencoded.
    pub fn isFormUrlEncoded(self: *const Self) bool {
        return self.request.isFormContent();
    }

    /// Returns true when request Accept allows the given media type.
    pub fn accepts(self: *const Self, media_type: []const u8) bool {
        return self.request.accepts(media_type);
    }

    /// Returns true when request Accept allows application/json.
    pub fn acceptsJson(self: *const Self) bool {
        return self.request.acceptsJson();
    }

    /// Returns a parsed cookie value by name from the request Cookie header.
    pub fn cookie(self: *const Self, name: []const u8) ?[]const u8 {
        const cookie_header = self.request.headers.get(HeaderName.COOKIE) orelse return null;
        return common.cookieValue(cookie_header, name);
    }

    /// Sets the response status code.
    pub fn status(self: *Self, code: u16) *Self {
        _ = self.response.status(code);
        return self;
    }

    /// Sets a response header.
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        _ = try self.response.header(name, value);
    }

    /// Appends a Set-Cookie header with common cookie attributes.
    pub fn setCookie(self: *Self, name: []const u8, value: []const u8, options: CookieOptions) !void {
        const set_cookie = try common.buildSetCookieHeader(self.allocator, name, value, options);
        defer self.allocator.free(set_cookie);
        try self.response.headers.append(HeaderName.SET_COOKIE, set_cookie);
    }

    /// Appends a Set-Cookie header that removes a cookie via Max-Age=0.
    pub fn removeCookie(self: *Self, name: []const u8, options: CookieOptions) !void {
        var remove_options = options;
        remove_options.max_age = 0;
        const remove_value = try common.buildSetCookieHeader(self.allocator, name, "", remove_options);
        defer self.allocator.free(remove_value);
        try self.response.headers.append(HeaderName.SET_COOKIE, remove_value);
    }

    /// Sends a plain text response.
    pub fn text(self: *Self, data: []const u8) !Response {
        _ = try self.response.header(HeaderName.CONTENT_TYPE, "text/plain; charset=utf-8");
        _ = self.response.body(data);
        return self.response.build();
    }

    /// Sends an HTML response.
    pub fn html(self: *Self, data: []const u8) !Response {
        _ = try self.response.header(HeaderName.CONTENT_TYPE, "text/html; charset=utf-8");
        _ = self.response.body(data);
        return self.response.build();
    }

    /// Sends a file response.
    pub fn file(self: *Self, path: []const u8) !Response {
        return self.fileWithOptions(path, .{});
    }

    /// Sends a file response with an explicit content type override.
    pub fn fileAs(self: *Self, path: []const u8, content_type: []const u8) !Response {
        return self.fileWithOptions(path, .{ .content_type = content_type });
    }

    /// Sends a file as an attachment download.
    pub fn download(self: *Self, path: []const u8, filename: ?[]const u8) !Response {
        var response = try self.file(path);

        if (filename) |name| {
            const disposition = try std.fmt.allocPrint(self.allocator, "attachment; filename=\"{s}\"", .{name});
            defer self.allocator.free(disposition);
            try response.headers.set(HeaderName.CONTENT_DISPOSITION, disposition);
        } else {
            try response.headers.set(HeaderName.CONTENT_DISPOSITION, "attachment");
        }

        return response;
    }

    /// Sends a file response with production-oriented static-file options.
    pub fn fileWithOptions(self: *Self, path: []const u8, options: FileResponseOptions) !Response {
        if (mem.indexOf(u8, path, "..") != null) {
            return self.status(status_mod.StatusCode.FORBIDDEN).text("Forbidden: Path Traversal Detected");
        }
        const io = defaultIo();
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return self.status(status_mod.StatusCode.NOT_FOUND).text("Not Found");
        defer f.close(io);

        const stat = try f.stat(io);
        const content_type = options.content_type orelse common.mimeTypeFromPath(path);

        var content_len_buf: [32]u8 = undefined;
        const content_len = std.fmt.bufPrint(&content_len_buf, "{d}", .{stat.size}) catch unreachable;
        _ = try self.response.header(HeaderName.CONTENT_LENGTH, content_len);
        _ = try self.response.header(HeaderName.CONTENT_TYPE, content_type);

        if (options.cache_control) |cache_control| {
            _ = try self.response.header(HeaderName.CACHE_CONTROL, cache_control);
        }

        if (options.add_nosniff) {
            _ = try self.response.header(HeaderName.X_CONTENT_TYPE_OPTIONS, "nosniff");
        }

        var etag_value: ?[]u8 = null;
        defer if (etag_value) |etag| self.allocator.free(etag);

        if (options.add_etag) {
            etag_value = try buildStaticEtag(self.allocator, path, stat);
            _ = try self.response.header(HeaderName.ETAG, etag_value.?);

            if (options.conditional_get) {
                if (self.request.headers.get(HeaderName.IF_NONE_MATCH)) |if_none_match| {
                    if (ifNoneMatchMatches(if_none_match, etag_value.?)) {
                        _ = self.response.status(status_mod.StatusCode.NOT_MODIFIED);
                        return self.response.build();
                    }
                }
            }
        }

        if (self.request.method == .HEAD) {
            return self.response.build();
        }

        if (stat.size > @as(u64, std.math.maxInt(usize))) {
            return error.ResponseTooLarge;
        }

        const content_len_usize: usize = @intCast(stat.size);
        const content = try self.allocator.alloc(u8, content_len_usize);
        defer self.allocator.free(content);

        const read_n = try f.readPositionalAll(io, content, 0);
        if (read_n != content_len_usize) {
            return error.UnexpectedEof;
        }

        _ = self.response.body(content);
        return self.response.build();
    }

    /// Sends chunked transfer-encoded payload with optional trailers.
    pub fn chunked(self: *Self, data: []const u8, trailers: ?*const Headers) !Response {
        const encoded = try http.encodeChunkedBody(data, trailers, self.allocator);
        defer self.allocator.free(encoded);

        _ = try self.response.header(HeaderName.TRANSFER_ENCODING, "chunked");
        if (trailers) |trailer_headers| {
            const trailer_names = try trailerHeaderNames(self.allocator, trailer_headers);
            defer self.allocator.free(trailer_names);
            _ = try self.response.header("Trailer", trailer_names);
        }
        _ = self.response.body(encoded);
        return self.response.build();
    }

    /// Sends one-shot Server-Sent Events payload.
    pub fn sse(self: *Self, events: []const SseEvent) !Response {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        const writer = list_writer.init(self.allocator, &payload);

        for (events) |evt| {
            if (evt.id) |id| try writer.print("id: {s}\n", .{id});
            if (evt.event) |name| try writer.print("event: {s}\n", .{name});
            if (evt.retry_ms) |retry_ms| try writer.print("retry: {d}\n", .{retry_ms});

            var lines = mem.splitScalar(u8, evt.data, '\n');
            while (lines.next()) |line| {
                try writer.print("data: {s}\n", .{line});
            }
            try writer.writeAll("\n");
        }

        _ = try self.response.header(HeaderName.CONTENT_TYPE, "text/event-stream; charset=utf-8");
        _ = try self.response.header(HeaderName.CACHE_CONTROL, "no-cache");
        _ = try self.response.header(HeaderName.CONNECTION, "keep-alive");
        _ = self.response.body(payload.items);
        return self.response.build();
    }

    /// Sends a JSON response.
    pub fn json(self: *Self, value: anytype) !Response {
        _ = try self.response.json(value);
        return self.response.build();
    }

    /// Parses the request body as JSON into the given type.
    /// The caller must call `deinit()` on the returned `std.json.Parsed(T)`.
    pub fn jsonBody(self: *const Self, comptime T: type, options: std.json.ParseOptions) !std.json.Parsed(T) {
        const body = self.request.body orelse return error.NoBody;
        return std.json.parseFromSlice(T, self.allocator, body, options);
    }

    /// Parses the request body as JSON into the given type using leaky allocation.
    pub fn jsonBodyLeaky(self: *const Self, comptime T: type, options: std.json.ParseOptions) !T {
        const body = self.request.body orelse return error.NoBody;
        return std.json.parseFromSliceLeaky(T, self.allocator, body, options);
    }

    /// Parses the request body as a dynamic JSON value.
    /// The caller must call `deinit()` on the returned `ParsedJson`.
    pub fn jsonValue(self: *const Self) !@import("../util/json.zig").ParsedJson {
        const body = self.request.body orelse return error.NoBody;
        return @import("../util/json.zig").Json.parseValue(self.allocator, body);
    }

    /// Returns 415 Unsupported Media Type if the request Content-Type is not JSON.
    /// Use this to guard handlers that require JSON input.
    pub fn requireJson(self: *const Self) !void {
        if (!self.isJson()) {
            return error.JsonContentTypeRequired;
        }
    }

    /// Sends a redirect response.
    pub fn redirect(self: *Self, url: []const u8, code: u16) !Response {
        _ = self.response.status(code);
        _ = try self.response.header(HeaderName.LOCATION, url);
        return self.response.build();
    }

    /// Sends a 204 No Content response.
    pub fn noContent(self: *Self) !Response {
        _ = self.response.status(status_mod.StatusCode.NO_CONTENT);
        return self.response.build();
    }
};

/// Handler function type.
pub const Handler = *const fn (*Context) anyerror!Response;

/// HTTP Server.
pub const Server = struct {
    allocator: Allocator,
    config: ServerConfig,
    router: Router,
    middleware: std.ArrayList(Middleware) = .empty,
    pre_route_hooks: std.ArrayList(PreRouteHook) = .empty,
    global_handler: ?Handler = null,
    listener: ?TcpListener = null,
    udp_socket: ?UdpSocket = null,
    unix_listener: ?@import("../net/unix.zig").UnixListener = null,
    running: bool = false,
    active_connections: std.ArrayList(Socket) = .empty,
    executor: ?Executor = null,
    executor_connections: std.ArrayList(Socket) = .empty,
    executor_conn_mutex: std.Io.Mutex = .init,
    server_tls_config: ?tls_mod.ServerTlsConfig = null,

    const Self = @This();

    /// Creates a server with default configuration.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates a server with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ServerConfig) Self {
        dbg.entry("SERVER", "initWithConfig");
        defer dbg.exit("SERVER", "initWithConfig");
        var cfg = config;
        if (cfg.max_connections == 0) cfg.max_connections = 1000;
        if (cfg.max_port_tries == 0) cfg.max_port_tries = 1;
        if (cfg.request_timeout_ms == 0) cfg.request_timeout_ms = 30_000;
        if (cfg.keep_alive_timeout_ms == 0) cfg.keep_alive_timeout_ms = 60_000;

        var executor: ?Executor = null;
        if (cfg.threads > 0) {
            executor = Executor.initWithConfig(allocator, .{ .num_threads = cfg.threads });
        }

        return .{
            .allocator = allocator,
            .config = cfg,
            .router = Router.init(allocator),
            .executor = executor,
        };
    }

    /// Releases all server resources.
    pub fn deinit(self: *Self) void {
        dbg.entry("SERVER", "deinit");
        defer dbg.exit("SERVER", "deinit");
        self.router.deinit();
        self.middleware.deinit(self.allocator);
        self.pre_route_hooks.deinit(self.allocator);
        self.active_connections.deinit(self.allocator);
        self.executor_connections.deinit(self.allocator);
        if (self.listener) |*l| l.deinit();
        if (self.udp_socket) |*u| u.close();
        if (self.executor) |*e| {
            e.deinit();
        }
        if (self.server_tls_config) |*tc| tc.deinit();
    }

    /// Adds middleware to the server.
    pub fn use(self: *Self, mw: Middleware) !void {
        try self.middleware.append(self.allocator, mw);
    }

    /// Adds a pre-route hook executed before route matching.
    pub fn preRoute(self: *Self, hook: PreRouteHook) !void {
        try self.pre_route_hooks.append(self.allocator, hook);
    }

    /// Registers a global fallback handler for unmatched routes.
    pub fn global(self: *Self, handler: Handler) void {
        self.global_handler = handler;
    }

    /// Registers a route handler.
    pub fn route(self: *Self, method: types.Method, path: []const u8, handler: Handler) !void {
        try self.router.add(method, path, handler);
    }

    /// Registers a GET route.
    pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.GET, path, handler);
    }

    /// Registers a POST route.
    pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.POST, path, handler);
    }

    /// Registers a PUT route.
    pub fn put(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.PUT, path, handler);
    }

    /// Registers a DELETE route.
    pub fn delete(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.DELETE, path, handler);
    }

    /// Registers a PATCH route.
    pub fn patch(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.PATCH, path, handler);
    }

    /// Registers a HEAD route.
    pub fn head(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.HEAD, path, handler);
    }

    /// Registers an OPTIONS route.
    pub fn options(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.OPTIONS, path, handler);
    }

    /// Registers a TRACE route.
    pub fn trace(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.TRACE, path, handler);
    }

    /// Registers a CONNECT route.
    pub fn connect(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.CONNECT, path, handler);
    }

    /// Registers a handler for all standard HTTP methods on a path.
    pub fn any(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.GET, path, handler);
        try self.route(.POST, path, handler);
        try self.route(.PUT, path, handler);
        try self.route(.DELETE, path, handler);
        try self.route(.PATCH, path, handler);
        try self.route(.HEAD, path, handler);
        try self.route(.OPTIONS, path, handler);
        try self.route(.TRACE, path, handler);
        try self.route(.CONNECT, path, handler);
    }

    /// Starts the server and begins accepting connections.
    ///
    /// When both `http2_enabled` and `http3_enabled` are set, the server
    /// binds a TCP listener (for HTTP/1.1 and HTTP/2) and a UDP socket (for
    /// HTTP/3 over QUIC) and runs both accept loops concurrently.
    pub fn listen(self: *Self) !void {
        if (self.config.unix_path) |path| {
            return self.listenUnix(path);
        }

        if (self.config.http3_enabled) {
            // Ensure TCP listener is bound for HTTP/1.1 and HTTP/2.
            if (self.listener == null) {
                const backlog_u32: u32 = @max(self.config.max_connections, 1);
                const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
                try self.bindTcpListener(backlog);
            }
            // Also bind UDP for HTTP/3 (graceful fallback).
            const udp_ok = blk: {
                self.bindUdpSocket() catch |err| {
                    self.log(.warn, "HTTP/3 UDP bind failed: {} — falling back to HTTP/1.1 + HTTP/2\n", .{err});
                    break :blk false;
                };
                break :blk true;
            };
            self.running = true;

            if (udp_ok) {
                self.log(.info, "Server listening on {s}:{d} (HTTP/1.1 + HTTP/2 + HTTP/3)\n", .{
                    self.config.host,
                    self.config.port,
                });
            } else {
                self.config.http3_enabled = false;
                self.log(.info, "Server listening on {s}:{d} (HTTP/1.1 + HTTP/2)\n", .{
                    self.config.host,
                    self.config.port,
                });
            }

            // Spawn TCP accept loop in a separate thread.
            const tcp_thread = try std.Thread.spawn(.{}, struct {
                fn run(s: *Self) void {
                    s.listenTcpAcceptLoop() catch |err| {
                        if (s.running) {
                            s.log(.err, "TCP accept error: {}\n", .{err});
                        }
                    };
                }
            }.run, .{self});
            defer tcp_thread.join();

            // Run HTTP/3 UDP recv loop only if UDP socket was bound.
            if (udp_ok) {
                return self.listenHttp3AcceptLoop();
            }
            // Otherwise wait for the TCP thread.
            tcp_thread.join();
            return;
        }

        return self.listenTcp();
    }

    /// Spawns a background thread to run the server's listening loop.
    /// The caller is responsible for joining the returned Thread.
    pub fn listenInBackground(self: *Self) !std.Thread {
        if (self.config.unix_path) |path| {
            if (self.unix_listener == null) {
                const unix_mod = @import("../net/unix.zig");
                self.unix_listener = try unix_mod.UnixListener.init(path);
            }
            return std.Thread.spawn(.{}, struct {
                fn run(s: *Self) void {
                    s.listen() catch |err| {
                        if (s.running) {
                            s.log(.err, "server error: {s}\n", .{@errorName(err)});
                        }
                    };
                }
            }.run, .{self});
        }

        if (self.config.http3_enabled) {
            // Bind TCP listener for HTTP/1.1 and HTTP/2.
            if (self.listener == null) {
                const backlog_u32: u32 = @max(self.config.max_connections, 1);
                const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
                try self.bindTcpListener(backlog);
            }
            // Bind UDP socket for HTTP/3 over QUIC (graceful fallback if bind fails).
            const udp_ok = blk: {
                self.bindUdpSocket() catch |err| {
                    self.log(.warn, "HTTP/3 UDP bind failed: {} — falling back to HTTP/1.1 + HTTP/2\n", .{err});
                    break :blk false;
                };
                break :blk true;
            };

            self.running = true;

            if (self.executor) |*e| {
                try e.start();
            }

            if (udp_ok) {
                self.log(.info, "Server listening on {s}:{d} (HTTP/1.1 + HTTP/2 + HTTP/3)\n", .{
                    self.config.host,
                    self.config.port,
                });
            } else {
                self.config.http3_enabled = false;
                self.log(.info, "Server listening on {s}:{d} (HTTP/1.1 + HTTP/2)\n", .{
                    self.config.host,
                    self.config.port,
                });
            }

            // Spawn TCP accept loop in a background thread.
            const tcp_thread = try std.Thread.spawn(.{}, struct {
                fn run(s: *Self) void {
                    s.listenTcpAcceptLoop() catch |err| {
                        if (s.running) {
                            s.log(.err, "TCP accept error: {}\n", .{err});
                        }
                    };
                }
            }.run, .{self});

            // Run HTTP/3 UDP recv loop only if UDP socket was successfully bound.
            if (udp_ok) {
                _ = try std.Thread.spawn(.{}, struct {
                    fn run(s: *Self) void {
                        s.listenHttp3AcceptLoop() catch |err| {
                            if (s.running) {
                                s.log(.err, "HTTP/3 accept error: {}\n", .{err});
                            }
                        };
                    }
                }.run, .{self});
            }

            return tcp_thread;
        }

        // Standard HTTP/1.1 + HTTP/2 path.
        if (self.listener == null) {
            const backlog_u32: u32 = @max(self.config.max_connections, 1);
            const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
            try self.bindTcpListener(backlog);
        }
        return std.Thread.spawn(.{}, struct {
            fn run(s: *Self) void {
                s.listen() catch |err| {
                    if (s.running) {
                        s.log(.err, "server error: {s}\n", .{@errorName(err)});
                    }
                };
            }
        }.run, .{self});
    }

    /// Logs a formatted message. If config.log_fn is provided, delegates to it.
    /// Otherwise, prints to stderr with tint.zig coloring based on log level.
    /// Messages below config.log_level are silently dropped.
    pub fn log(self: *const Self, level: LogLevel, comptime format: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.config.log_level)) return;
        if (self.config.log_fn) |log_fn| {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, format, args)) |msg| {
                log_fn(level, msg);
            } else |_| {
                log_fn(level, "[Log format failed or message too long]");
            }
        } else {
            const level_style = switch (level) {
                .debug => tint.style(.{ .fg = .{ .ansi4 = .bright_black }, .dim = true }),
                .info => tint.style(.{ .fg = .{ .ansi4 = .bright_green } }),
                .warn => tint.style(.{ .fg = .{ .ansi4 = .bright_yellow }, .bold = true }),
                .err => tint.style(.{ .fg = .{ .ansi4 = .bright_red }, .bold = true }),
            };
            const prefix = switch (level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
            const app_style = tint.style(.{ .fg = .{ .ansi4 = .bright_cyan }, .bold = true });
            std.debug.print(
                "{s}HTTPX{s} {s}[{s}]{s} " ++ format ++ "\n",
                .{ app_style.toAnsi(), tint.reset, level_style.toAnsi(), prefix, tint.reset } ++ args,
            );
        }
    }

    /// Returns the effective server port (useful when `port_conflict = .increment`).
    pub fn listeningPort(self: *const Self) u16 {
        return self.config.port;
    }

    fn maxPortBindAttempts(self: *const Self) u16 {
        return if (self.config.port_conflict == .increment)
            @max(self.config.max_port_tries, 1)
        else
            1;
    }

    fn portCandidate(base: u16, attempt: u16) ?u16 {
        const candidate_u32 = @as(u32, base) + @as(u32, attempt);
        if (candidate_u32 > std.math.maxInt(u16)) return null;
        return @intCast(candidate_u32);
    }

    fn bindTcpListener(self: *Self, backlog: u31) !void {
        const attempts = self.maxPortBindAttempts();
        var attempt: u16 = 0;

        while (attempt < attempts) : (attempt += 1) {
            const candidate_port = portCandidate(self.config.port, attempt) orelse return error.PortRangeExhausted;
            const addr = try net.Address.parseIp(self.config.host, candidate_port);

            const listener = TcpListener.initWithBacklog(addr, backlog) catch |err| switch (err) {
                error.AddressInUse, error.BindFailed => {
                    if (self.config.port_conflict == .increment and attempt + 1 < attempts) {
                        continue;
                    }
                    return err;
                },
                else => return err,
            };

            self.listener = listener;
            const actual_addr = try self.listener.?.getLocalAddress();
            self.config.port = actual_addr.getPort();
            return;
        }

        return error.PortRangeExhausted;
    }

    fn bindUdpSocket(self: *Self) !void {
        const attempts = self.maxPortBindAttempts();
        var attempt: u16 = 0;

        while (attempt < attempts) : (attempt += 1) {
            const candidate_port = portCandidate(self.config.port, attempt) orelse return error.PortRangeExhausted;
            const addr = try net.Address.parseIp(self.config.host, candidate_port);

            var socket = try UdpSocket.createForAddress(addr);
            if (socket.bind(addr)) {
                if (self.config.request_timeout_ms > 0) {
                    socket.setRecvTimeout(self.config.request_timeout_ms) catch |err| {
                        socket.close();
                        return err;
                    };
                }

                self.udp_socket = socket;
                const actual_addr = try self.udp_socket.?.getLocalAddress();
                self.config.port = actual_addr.getPort();
                return;
            } else |err| {
                socket.close();
                if (self.config.port_conflict == .increment and attempt + 1 < attempts) {
                    continue;
                }
                return err;
            }
        }

        return error.PortRangeExhausted;
    }

    fn listenTcp(self: *Self) !void {
        dbg.entry("SERVER", "listenTcp");
        defer dbg.exit("SERVER", "listenTcp");
        if (self.listener == null) {
            const backlog_u32: u32 = @max(self.config.max_connections, 1);
            const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
            try self.bindTcpListener(backlog);
        }
        self.running = true;

        if (self.executor) |*e| {
            try e.start();
        }

        self.log(.info, "Server listening on {s}:{d}\n", .{ self.config.host, self.config.port });

        dbg.log("SERVER", "accept loop starting on {s}:{d}", .{ self.config.host, self.config.port });
        try self.listenTcpAcceptLoop();
    }

    /// TCP accept loop -- accepts connections and dispatches to handler.
    /// Called from `listenTcp` (standalone) or from a background thread when
    /// running alongside HTTP/3.
    fn listenTcpAcceptLoop(self: *Self) !void {
        dbg.entry("SERVER", "listenTcpAcceptLoop");
        defer dbg.exit("SERVER", "listenTcpAcceptLoop");
        while (self.running) {
            // Wait for the listener socket to be readable (connection pending)
            // with a 500ms timeout so we can re-check self.running for clean
            // shutdown. On Windows, closesocket() from another thread may not
            // unblock a blocking accept().
            if (self.listener) |*l| {
                if (!l.socket.waitReadable(500)) continue;
            } else break;
            // Re-check after waitReadable — stop() may have nulled the
            // listener during the 500ms wait.
            if (!self.running or self.listener == null) break;
            const conn = self.listener.?.accept() catch {
                if (!self.running) break;
                continue;
            };

            dbg.log("SERVER", "accepted connection", .{});
            self.dispatchToExecutor(conn.socket);
        }
    }

    fn listenHttp3(self: *Self) !void {
        if (self.udp_socket == null) {
            try self.bindUdpSocket();
        }
        self.running = true;

        self.log(.info, "Server listening (HTTP/3) on {s}:{d}\n", .{ self.config.host, self.config.port });

        try self.listenHttp3AcceptLoop();
    }

    /// HTTP/3 UDP recv loop -- receives QUIC packets and dispatches to handler.
    /// Called from `listenHttp3` (standalone) or from the current thread when
    /// running alongside TCP.
    fn listenHttp3AcceptLoop(self: *Self) !void {
        var recv_buf: [64 * 1024]u8 = undefined;

        while (self.running) {
            const incoming = self.udp_socket.?.recvFrom(&recv_buf) catch |err| {
                if (!self.running) break;
                self.log(.err, "HTTP/3 recv error: {}\n", .{err});
                continue;
            };

            self.handleHttp3Transaction(incoming.addr, recv_buf[0..incoming.n]) catch |err| {
                self.log(.err, "HTTP/3 handler error: {}\n", .{err});
            };
        }
    }

    /// Dispatches a socket connection to the executor thread pool, or handles
    /// it directly on the current thread when no executor is configured.
    fn dispatchToExecutor(self: *Self, socket: Socket) void {
        if (self.executor) |*e| {
            dbg.log("SERVER", "dispatching to executor thread pool", .{});
            const ConnJob = struct {
                server: *Self,
                socket: Socket,
                fn run(ctx_ptr: ?*anyopaque) void {
                    const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
                    ctx.server.handleConnection(ctx.socket) catch |err| {
                        switch (err) {
                            error.TlsConnectionTruncated, error.EndOfStream, error.ConnectionReset, error.RecvFailed, error.SendFailed => {},
                            else => ctx.server.log(.err, "Handler error: {}\n", .{err}),
                        }
                    };
                    // Remove from executor tracking.
                    const io = defaultIo();
                    ctx.server.executor_conn_mutex.lock(io) catch unreachable;
                    for (ctx.server.executor_connections.items, 0..) |*s, i| {
                        if (s.handle == ctx.socket.handle) {
                            _ = ctx.server.executor_connections.orderedRemove(i);
                            break;
                        }
                    }
                    ctx.server.executor_conn_mutex.unlock(io);
                    ctx.server.allocator.destroy(ctx);
                }
            };
            const job_ctx = self.allocator.create(ConnJob) catch {
                var s = socket;
                s.close();
                return;
            };
            job_ctx.* = .{
                .server = self,
                .socket = socket,
            };
            // Track in executor connections so stop() can close it.
            {
                const io = defaultIo();
                self.executor_conn_mutex.lock(io) catch unreachable;
                self.executor_connections.append(self.allocator, socket) catch {};
                self.executor_conn_mutex.unlock(io);
            }
            e.submit(.{
                .func = ConnJob.run,
                .context = job_ctx,
            }) catch |err| {
                self.log(.err, "Executor submission failed: {s}\n", .{@errorName(err)});
                {
                    const io = defaultIo();
                    self.executor_conn_mutex.lock(io) catch unreachable;
                    for (self.executor_connections.items, 0..) |*s, i| {
                        if (s.handle == socket.handle) {
                            _ = self.executor_connections.orderedRemove(i);
                            break;
                        }
                    }
                    self.executor_conn_mutex.unlock(io);
                }
                var s = socket;
                s.close();
                self.allocator.destroy(job_ctx);
            };
        } else {
            self.active_connections.append(self.allocator, socket) catch {};
            self.handleConnection(socket) catch |err| {
                // TlsConnectionTruncated and EndOfStream are normal client disconnections,
                // not errors — don't pollute stderr with them.
                switch (err) {
                    error.TlsConnectionTruncated, error.EndOfStream, error.ConnectionReset, error.RecvFailed, error.SendFailed => {},
                    else => self.log(.err, "Handler error: {}\n", .{err}),
                }
            };
            self.removeFromActive(socket);
        }
    }

    fn removeFromActive(self: *Self, socket: Socket) void {
        for (self.active_connections.items, 0..) |*s, i| {
            if (s.handle == socket.handle) {
                _ = self.active_connections.swapRemove(i);
                return;
            }
        }
    }

    /// Parses pseudo-headers (:method, :path, :scheme, :authority) from a
    /// decoded header block and appends regular headers to `request_headers`.
    fn parseHeaders(
        self: *Self,
        comptime HeaderT: type,
        entries: []const HeaderT,
        request_headers: *Headers,
        method: *[]const u8,
        method_owned: *bool,
        path: *[]const u8,
        path_owned: *bool,
        scheme: *[]const u8,
        scheme_owned: *bool,
        authority: *?[]const u8,
        authority_owned: *bool,
    ) !void {
        for (entries) |h| {
            if (h.name.len > 0 and h.name[0] == ':') {
                if (mem.eql(u8, h.name, ":method")) {
                    if (method_owned.*) self.allocator.free(method.*);
                    method.* = try self.allocator.dupe(u8, h.value);
                    method_owned.* = true;
                } else if (mem.eql(u8, h.name, ":path")) {
                    if (path_owned.*) self.allocator.free(path.*);
                    path.* = try self.allocator.dupe(u8, h.value);
                    path_owned.* = true;
                } else if (mem.eql(u8, h.name, ":scheme")) {
                    if (scheme_owned.*) self.allocator.free(scheme.*);
                    scheme.* = try self.allocator.dupe(u8, h.value);
                    scheme_owned.* = true;
                } else if (mem.eql(u8, h.name, ":authority")) {
                    if (authority_owned.*) {
                        if (authority.*) |a| self.allocator.free(a);
                    }
                    authority.* = try self.allocator.dupe(u8, h.value);
                    authority_owned.* = true;
                }
                continue;
            }

            if (common.isConnectionSpecificHeader(h.name)) continue;
            try request_headers.append(h.name, h.value);
        }
    }

    /// Stops the server.
    pub fn stop(self: *Self) void {
        dbg.entry("SERVER", "stop");
        self.running = false;
        for (self.active_connections.items) |*s| {
            s.close();
        }
        self.active_connections.clearRetainingCapacity();
        // Close executor-tracked sockets so worker threads unblock from recv().
        {
            const io = defaultIo();
            self.executor_conn_mutex.lock(io) catch unreachable;
            for (self.executor_connections.items) |*s| {
                s.close();
            }
            self.executor_connections.clearRetainingCapacity();
            self.executor_conn_mutex.unlock(io);
        }
        if (self.listener) |*l| {
            // Close the socket first to immediately unblock any pending accept() on Windows.
            // shutdown() alone may not unblock a blocking accept() on all platforms.
            l.deinit();
            self.listener = null;
        }
        if (self.udp_socket) |*u| {
            u.close();
            self.udp_socket = null;
        }
        if (self.unix_listener) |*u| {
            var sock = Socket.fromHandle(u.fd);
            sock.shutdownBoth() catch {};
            u.deinit();
            self.unix_listener = null;
        }
        if (self.executor) |*e| {
            e.stop();
        }
    }

    fn listenUnix(self: *Self, path: []const u8) !void {
        if (self.unix_listener == null) {
            const unix_mod = @import("../net/unix.zig");
            self.unix_listener = try unix_mod.UnixListener.init(path);
        }
        self.running = true;

        if (self.executor) |*e| {
            try e.start();
        }

        self.log(.info, "Server listening on Unix socket: {s}\n", .{path});

        while (self.running) {
            const conn = self.unix_listener.?.accept() catch |err| {
                if (!self.running) break;
                self.log(.err, "Unix Accept error: {}\n", .{err});
                continue;
            };

            const socket_wrapper = Socket.fromHandle(conn.socket.fd);
            self.dispatchToExecutor(socket_wrapper);
        }
    }

    /// Handles a single connection.
    fn handleConnection(self: *Self, socket: Socket) !void {
        dbg.entry("SERVER", "handleConnection");
        var sock = socket;

        if (self.config.tls_enabled) {
            dbg.log("SERVER", "TLS enabled, negotiating", .{});
            // Use config.tls_alpn_protocols when set (non-default), otherwise
            // build dynamically from enabled protocols.
            const alpn_protos: []const []const u8 = if (self.config.http3_enabled and self.config.http2_enabled)
                &.{ "h3", "h2", "http/1.1" }
            else if (self.config.http2_enabled)
                &.{ "h2", "http/1.1" }
            else
                &.{"http/1.1"};

            // Load TLS cert/key if not already loaded
            if (self.server_tls_config == null) {
                if (self.config.tls_cert_path) |cert_path| {
                    if (self.config.tls_key_path) |key_path| {
                        self.server_tls_config = tls_mod.loadServerTlsConfig(self.allocator, cert_path, key_path) catch |err| {
                            self.log(.err, "Failed to load TLS cert/key: {}\n", .{err});
                            return;
                        };
                    }
                }
            }

            var tls_conn = tls_mod.acceptServer(self.allocator, &sock, alpn_protos, self.server_tls_config) catch |err| {
                self.log(.err, "TLS accept failed: {}\n", .{err});
                return;
            };
            defer tls_conn.closeNotify();

            const alpn_protocol = tls_conn.negotiatedAlpn() orelse "http/1.1";

            // Use the alpn module's helper which handles h3 draft versions.
            if (alpn.isHttp3(alpn_protocol) and self.config.http3_enabled) {
                // HTTP/3 over TLS typically runs over QUIC (UDP), not TCP.
                // If the server receives an h3 ALPN over TCP, it means the
                // client expects QUIC.  Send an ALPN alert and close.
                self.log(.warn, "Client negotiated h3 over TCP; HTTP/3 requires QUIC/UDP\n", .{});
                tls_conn.sendAlert(.fatal, .protocol_version);
                return;
            }
            if (alpn.isHttp2(alpn_protocol) and self.config.http2_enabled) {
                dbg.log("SERVER", "ALPN negotiated HTTP/2 over TLS", .{});
                return self.handleHttp2WithTls(&tls_conn);
            }
            dbg.log("SERVER", "TLS fallback to HTTP/1.1", .{});
            return self.handleHttp1WithTls(&tls_conn);
        }

        if (self.config.http2_enabled) {
            // Read the first bytes to detect the HTTP/2 connection preface.
            // If the client sends the 24-byte preface, handle as HTTP/2;
            // otherwise those bytes are the start of an HTTP/1.1 request.
            var probe: [http.HTTP2_PREFACE.len]u8 = undefined;
            var total: usize = 0;
            while (total < probe.len) {
                const n = sock.recv(probe[total..]) catch break;
                if (n == 0) return;
                total += n;
            }

            if (total == probe.len and mem.eql(u8, &probe, http.HTTP2_PREFACE)) {
                dbg.log("SERVER", "detected HTTP/2 connection preface", .{});
                return self.handleHttp2Connection(sock);
            }

            // Not HTTP/2 -- handle as HTTP/1.1 with the already-read prefix.
            return self.handleHttp1WithPrefix(sock, probe[0..total]);
        }

        return self.handleHttp1Connection(sock);
    }

    /// Handles an HTTP/1.1 connection from scratch (no prefix bytes).
    fn handleHttp1Connection(self: *Self, sock: Socket) !void {
        return self.handleHttp1WithPrefix(sock, &.{});
    }

    /// Handles an HTTP/1.1 connection where `prefix` bytes have already been
    /// read from the socket (e.g. during HTTP/2 preface detection).
    fn handleHttp1WithPrefix(self: *Self, socket: Socket, prefix: []const u8) !void {
        dbg.entry("SERVER", "handleHttp1WithPrefix");
        defer dbg.exit("SERVER", "handleHttp1WithPrefix");
        var sock = socket;
        var first_request = true;
        while (self.running) {
            const timeout_ms = if (first_request) self.config.request_timeout_ms else self.config.keep_alive_timeout_ms;
            if (timeout_ms > 0) {
                try sock.setRecvTimeout(timeout_ms);
            }

            var buffer: [8192]u8 = undefined;
            var parser = Parser.init(self.allocator);
            defer parser.deinit();

            // If prefix bytes were provided, feed them first.
            if (!first_request or prefix.len == 0) {
                // No prefix or subsequent request -- normal read path.
            } else if (prefix.len > 0) {
                _ = try parser.feed(prefix);
                if (parser.getBody().len > self.config.max_body_size) {
                    try self.sendError(&sock, 413);
                    return;
                }
            }

            while (!parser.isComplete()) {
                const n = try sock.recv(&buffer);
                if (n == 0) {
                    dbg.log("SERVER", "recv returned 0, client disconnected", .{});
                    return;
                }
                _ = try parser.feed(buffer[0..n]);
                if (parser.getBody().len > self.config.max_body_size) {
                    try self.sendError(&sock, 413);
                    return;
                }
            }

            var req = try Request.init(
                self.allocator,
                parser.method orelse .GET,
                parser.path orelse "/",
            );
            defer req.deinit();
            req.version = parser.version;

            for (parser.headers.entries.items) |h| {
                try req.headers.append(h.name, h.value);
            }

            if (parser.getBody().len > 0) {
                req.body = parser.getBody();
            }

            var response = self.executeServerRequest(&req) catch |err| {
                self.log(.err, "Handler error: {}\n", .{err});
                return self.sendError(&sock, status_mod.StatusCode.INTERNAL_SERVER_ERROR);
            };

            defer response.deinit();

            const request_wants_keep_alive = req.headers.isKeepAlive(req.version);
            const keep_alive = self.config.keep_alive and request_wants_keep_alive;
            dbg.log("SERVER", "HTTP/1.1 keep-alive={}", .{keep_alive});
            if (!keep_alive) {
                try response.headers.set(HeaderName.CONNECTION, "close");
            }

            try self.ensureContentLengthHeader(&response);

            const formatted = try http.formatResponse(&response, self.allocator);
            defer self.allocator.free(formatted);

            try sock.sendAll(formatted);

            dbg.log("SERVER", "response sent {d}", .{response.status.code});

            if (!keep_alive) return;
            first_request = false;
        }
    }

    /// Handles an HTTP/1.1 connection over TLS.
    fn handleHttp1WithTls(self: *Self, tls_conn: *tls_mod.Connection) !void {
        dbg.entry("SERVER", "handleHttp1WithTls");
        defer dbg.exit("SERVER", "handleHttp1WithTls");
        var first_request = true;
        while (self.running) {
            const timeout_ms = if (first_request) self.config.request_timeout_ms else self.config.keep_alive_timeout_ms;
            _ = timeout_ms;

            var parser = Parser.init(self.allocator);
            defer parser.deinit();

            while (!parser.isComplete()) {
                var read_buf: [4096]u8 = undefined;
                const n = tls_conn.read(&read_buf) catch |err| {
                    self.log(.err, "TLS read error: {}\n", .{err});
                    return;
                };
                if (n == 0) {
                    dbg.log("SERVER", "TLS recv returned 0, client disconnected", .{});
                    return;
                }
                _ = try parser.feed(read_buf[0..n]);
                if (parser.getBody().len > self.config.max_body_size) {
                    try self.sendTlsError(tls_conn, 413);
                    return;
                }
            }

            var req = try Request.init(
                self.allocator,
                parser.method orelse .GET,
                parser.path orelse "/",
            );
            defer req.deinit();
            req.version = parser.version;

            for (parser.headers.entries.items) |h| {
                try req.headers.append(h.name, h.value);
            }

            if (parser.getBody().len > 0) {
                req.body = parser.getBody();
            }

            var response = self.executeServerRequest(&req) catch |err| {
                self.log(.err, "Handler error: {}\n", .{err});
                return self.sendTlsError(tls_conn, status_mod.StatusCode.INTERNAL_SERVER_ERROR);
            };

            defer response.deinit();

            const request_wants_keep_alive = req.headers.isKeepAlive(req.version);
            const keep_alive = self.config.keep_alive and request_wants_keep_alive;
            if (!keep_alive) {
                try response.headers.set(HeaderName.CONNECTION, "close");
            }

            try self.ensureContentLengthHeader(&response);

            const formatted = try http.formatResponse(&response, self.allocator);
            defer self.allocator.free(formatted);

            tls_conn.writeAll(formatted) catch |err| {
                self.log(.err, "TLS write error: {}\n", .{err});
                return;
            };

            dbg.log("SERVER", "TLS response sent {d}", .{response.status.code});

            if (!keep_alive) return;
            first_request = false;
        }
    }

    /// Handles an HTTP/2 connection over TLS.
    fn handleHttp2WithTls(self: *Self, tls_conn: *tls_mod.Connection) !void {
        dbg.entry("SERVER", "handleHttp2WithTls");
        defer dbg.exit("SERVER", "handleHttp2WithTls");
        // The TLS handshake has already been completed.
        if (self.config.request_timeout_ms > 0) {
            // TLS connections don't have socket-level timeouts, but we can
            // still enforce application-level timeouts via the read loop.
        }

        var conn = http.Http2Connection.init(
            self.allocator,
            tls_conn.reader(),
            tls_conn.writer(),
        );

        try conn.writeFrame(.{
            .length = 0,
            .frame_type = .settings,
            .flags = 0,
            .stream_id = 0,
        }, &.{});

        var stream_manager = h2stream.StreamManager.init(self.allocator, false);
        defer stream_manager.deinit();

        var request_headers = Headers.init(self.allocator);
        defer request_headers.deinit();

        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        var method_raw: []const u8 = "GET";
        var method_owned = false;
        defer if (method_owned) self.allocator.free(method_raw);

        var path_raw: []const u8 = "/";
        var path_owned = false;
        defer if (path_owned) self.allocator.free(path_raw);

        var scheme_raw: []const u8 = "https";
        var scheme_owned = false;
        defer if (scheme_owned) self.allocator.free(scheme_raw);

        var authority_raw: ?[]const u8 = null;
        var authority_owned = false;
        defer if (authority_owned and authority_raw != null) self.allocator.free(authority_raw.?);

        var request_stream_id: ?u31 = null;
        var request_done = false;

        var peer_max_frame_size: u32 = 16384;
        var client_push_enabled: bool = self.config.enable_push;

        var pending_headers_block = std.ArrayList(u8).empty;
        defer pending_headers_block.deinit(self.allocator);
        var pending_headers_flags: u8 = 0;
        var waiting_continuation = false;

        const max_frame_payload = self.config.max_body_size + (1024 * 1024);

        while (!request_done) {
            var frame = try conn.readFrame(self.allocator, max_frame_payload);
            defer frame.deinit(self.allocator);

            switch (frame.header.frame_type) {
                .settings => {
                    if ((frame.header.flags & 0x01) == 0) {
                        var parsed_settings = conn.peer_settings;
                        try http.applySettingsPayload(&parsed_settings, frame.payload);
                        try stream_manager.applyPeerSettings(parsed_settings);
                        conn.peer_settings = parsed_settings;
                        peer_max_frame_size = parsed_settings.max_frame_size;
                        client_push_enabled = self.config.enable_push and parsed_settings.enable_push;
                        try conn.writeFrame(.{
                            .length = 0,
                            .frame_type = .settings,
                            .flags = 0x01,
                            .stream_id = 0,
                        }, &.{});
                    }
                },
                .ping => {
                    if ((frame.header.flags & 0x01) == 0 and frame.payload.len == 8) {
                        try conn.writeFrame(.{
                            .length = 8,
                            .frame_type = .ping,
                            .flags = 0x01,
                            .stream_id = 0,
                        }, frame.payload);
                    }
                },
                .headers => {
                    if (frame.header.stream_id == 0) return error.ProtocolError;

                    if (request_stream_id == null) {
                        request_stream_id = frame.header.stream_id;
                    }
                    // Send RST_STREAM for concurrent streams (single-stream server).
                    if (frame.header.stream_id != request_stream_id.?) {
                        const rst_frame = h2stream.buildRstStreamFrame(frame.header.stream_id, .refused_stream);
                        try conn.writer.writeAll(&rst_frame);
                        continue;
                    }

                    if (waiting_continuation) return error.ProtocolError;

                    if ((frame.header.flags & 0x04) != 0) {
                        const parsed = try h2stream.parseHeadersFramePayload(
                            &stream_manager,
                            frame.payload,
                            frame.header.flags,
                            self.allocator,
                        );
                        defer {
                            for (parsed.headers) |header| {
                                self.allocator.free(header.name);
                                self.allocator.free(header.value);
                            }
                            self.allocator.free(parsed.headers);
                        }

                        try self.parseHeaders(
                            @TypeOf(parsed.headers[0]),
                            parsed.headers,
                            &request_headers,
                            &method_raw,
                            &method_owned,
                            &path_raw,
                            &path_owned,
                            &scheme_raw,
                            &scheme_owned,
                            &authority_raw,
                            &authority_owned,
                        );
                    } else {
                        pending_headers_flags = frame.header.flags;
                        try pending_headers_block.appendSlice(self.allocator, frame.payload);
                        waiting_continuation = true;
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        request_done = true;
                    }
                },
                .continuation => {
                    if (!waiting_continuation) return error.ProtocolError;
                    if (request_stream_id == null or frame.header.stream_id != request_stream_id.?) continue;

                    try pending_headers_block.appendSlice(self.allocator, frame.payload);
                    if ((frame.header.flags & 0x04) != 0) {
                        const parsed = try h2stream.parseHeadersFramePayload(
                            &stream_manager,
                            pending_headers_block.items,
                            pending_headers_flags,
                            self.allocator,
                        );
                        defer {
                            for (parsed.headers) |header| {
                                self.allocator.free(header.name);
                                self.allocator.free(header.value);
                            }
                            self.allocator.free(parsed.headers);
                        }

                        try self.parseHeaders(
                            @TypeOf(parsed.headers[0]),
                            parsed.headers,
                            &request_headers,
                            &method_raw,
                            &method_owned,
                            &path_raw,
                            &path_owned,
                            &scheme_raw,
                            &scheme_owned,
                            &authority_raw,
                            &authority_owned,
                        );

                        pending_headers_block.clearRetainingCapacity();
                        waiting_continuation = false;

                        if ((pending_headers_flags & 0x01) != 0) {
                            request_done = true;
                        }
                    }
                },
                .data => {
                    if (request_stream_id == null) continue;
                    // Send RST_STREAM for concurrent streams (single-stream server).
                    if (frame.header.stream_id != request_stream_id.?) {
                        const rst_frame = h2stream.buildRstStreamFrame(frame.header.stream_id, .refused_stream);
                        try conn.writer.writeAll(&rst_frame);
                        continue;
                    }

                    var data_slice = frame.payload;
                    if ((frame.header.flags & 0x08) != 0) {
                        if (frame.payload.len == 0) return error.ProtocolError;
                        const pad_len = frame.payload[0];
                        if (frame.payload.len < @as(usize, pad_len) + 1) return error.ProtocolError;
                        data_slice = frame.payload[1 .. frame.payload.len - pad_len];
                    }

                    if (request_body.items.len + data_slice.len > self.config.max_body_size) {
                        return error.RequestTooLarge;
                    }
                    try request_body.appendSlice(self.allocator, data_slice);

                    if (data_slice.len > 0) {
                        const window_increment: u31 = @intCast(data_slice.len);
                        const window_update = h2stream.buildWindowUpdatePayload(window_increment);

                        try conn.writeFrame(.{
                            .length = @intCast(window_update.len),
                            .frame_type = .window_update,
                            .flags = 0,
                            .stream_id = request_stream_id.?,
                        }, &window_update);

                        try conn.writeFrame(.{
                            .length = @intCast(window_update.len),
                            .frame_type = .window_update,
                            .flags = 0,
                            .stream_id = 0,
                        }, &window_update);
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        request_done = true;
                    }
                },
                .rst_stream => {
                    if (request_stream_id != null and frame.header.stream_id == request_stream_id.?) {
                        request_done = true;
                    }
                },
                .goaway => {
                    return;
                },
                .window_update, .priority, .push_promise => {},
                _ => {},
            }
        }

        if (waiting_continuation) return error.ProtocolError;

        const stream_id = request_stream_id orelse return error.ProtocolError;

        const scheme = if (scheme_raw.len == 0) "https" else scheme_raw;
        const path = if (path_raw.len == 0) "/" else path_raw;
        const authority = authority_raw orelse request_headers.get(HeaderName.HOST) orelse self.config.host;
        if (request_headers.get(HeaderName.HOST) == null) {
            try request_headers.append(HeaderName.HOST, authority);
        }

        const method = types.Method.fromString(method_raw) orelse .GET;

        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, authority, path });
        defer self.allocator.free(url);

        var req = try Request.init(self.allocator, method, url);
        defer req.deinit();
        req.version = .HTTP_2;

        req.headers.deinit();
        req.headers = Headers.init(self.allocator);
        for (request_headers.entries.items) |entry| {
            try req.headers.append(entry.name, entry.value);
        }

        if (request_body.items.len > 0) {
            req.body = try self.allocator.dupe(u8, request_body.items);
            req.body_owned = true;
        }

        var response = self.executeServerRequest(&req) catch {
            var internal = Response.init(self.allocator, status_mod.StatusCode.INTERNAL_SERVER_ERROR);
            defer internal.deinit();
            internal.version = .HTTP_2;
            try self.sendHttp2Response(&conn, &stream_manager, stream_id, &internal);
            const goaway_frame = try h2stream.buildGoawayFrame(stream_id, .internal_error, null, self.allocator);
            defer self.allocator.free(goaway_frame);
            try conn.writer.writeAll(goaway_frame);
            return;
        };
        defer response.deinit();
        response.version = .HTTP_2;

        try self.sendHttp2Response(&conn, &stream_manager, stream_id, &response);

        const goaway_frame = try h2stream.buildGoawayFrame(stream_id, .no_error, null, self.allocator);
        defer self.allocator.free(goaway_frame);
        try conn.writer.writeAll(goaway_frame);
    }

    /// Sends an error response over a TLS connection.
    fn sendTlsError(self: *Self, tls_conn: *tls_mod.Connection, code: u16) !void {
        var resp = Response.init(self.allocator, code);
        defer resp.deinit();

        try self.ensureContentLengthHeader(&resp);

        const formatted = try http.formatResponse(&resp, self.allocator);
        defer self.allocator.free(formatted);

        tls_conn.writeAll(formatted) catch |e| {
            self.log(.err, "TLS write failed: {}\n", .{e});
            return;
        };
    }

    fn handleHttp2Connection(self: *Self, socket: Socket) !void {
        dbg.entry("SERVER", "handleHttp2Connection");
        defer dbg.exit("SERVER", "handleHttp2Connection");
        var sock = socket;
        defer sock.close();

        // The HTTP/2 connection preface has already been consumed by
        // handleConnection(). Set recv timeout for subsequent reads.
        if (self.config.request_timeout_ms > 0) {
            try sock.setRecvTimeout(self.config.request_timeout_ms);
        }

        var conn = http.Http2Connection.init(
            self.allocator,
            sock.reader(),
            sock.writer(),
        );

        try conn.writeFrame(.{
            .length = 0,
            .frame_type = .settings,
            .flags = 0,
            .stream_id = 0,
        }, &.{});

        var stream_manager = h2stream.StreamManager.init(self.allocator, false);
        defer stream_manager.deinit();

        var request_headers = Headers.init(self.allocator);
        defer request_headers.deinit();

        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        var method_raw: []const u8 = "GET";
        var method_owned = false;
        defer if (method_owned) self.allocator.free(method_raw);

        var path_raw: []const u8 = "/";
        var path_owned = false;
        defer if (path_owned) self.allocator.free(path_raw);

        var scheme_raw: []const u8 = "http";
        var scheme_owned = false;
        defer if (scheme_owned) self.allocator.free(scheme_raw);

        var authority_raw: ?[]const u8 = null;
        var authority_owned = false;
        defer if (authority_owned and authority_raw != null) self.allocator.free(authority_raw.?);

        var request_stream_id: ?u31 = null;
        var request_done = false;

        var peer_max_frame_size: u32 = 16384;
        var client_push_enabled: bool = self.config.enable_push;

        var pending_headers_block = std.ArrayList(u8).empty;
        defer pending_headers_block.deinit(self.allocator);
        var pending_headers_flags: u8 = 0;
        var waiting_continuation = false;

        const max_frame_payload = self.config.max_body_size + (1024 * 1024);

        while (!request_done) {
            var frame = try conn.readFrame(self.allocator, max_frame_payload);
            defer frame.deinit(self.allocator);

            switch (frame.header.frame_type) {
                .settings => {
                    if ((frame.header.flags & 0x01) == 0) {
                        var parsed_settings = conn.peer_settings;
                        try http.applySettingsPayload(&parsed_settings, frame.payload);
                        try stream_manager.applyPeerSettings(parsed_settings);
                        conn.peer_settings = parsed_settings;
                        peer_max_frame_size = parsed_settings.max_frame_size;
                        client_push_enabled = self.config.enable_push and parsed_settings.enable_push;
                        try conn.writeFrame(.{
                            .length = 0,
                            .frame_type = .settings,
                            .flags = 0x01,
                            .stream_id = 0,
                        }, &.{});
                    }
                },
                .ping => {
                    if ((frame.header.flags & 0x01) == 0 and frame.payload.len == 8) {
                        try conn.writeFrame(.{
                            .length = 8,
                            .frame_type = .ping,
                            .flags = 0x01,
                            .stream_id = 0,
                        }, frame.payload);
                    }
                },
                .headers => {
                    if (frame.header.stream_id == 0) return error.ProtocolError;

                    if (request_stream_id == null) {
                        request_stream_id = frame.header.stream_id;
                    }
                    // Send RST_STREAM for concurrent streams (single-stream server).
                    if (frame.header.stream_id != request_stream_id.?) {
                        const rst_frame = h2stream.buildRstStreamFrame(frame.header.stream_id, .refused_stream);
                        try conn.writer.writeAll(&rst_frame);
                        continue;
                    }

                    if (waiting_continuation) return error.ProtocolError;

                    if ((frame.header.flags & 0x04) != 0) {
                        const parsed = try h2stream.parseHeadersFramePayload(
                            &stream_manager,
                            frame.payload,
                            frame.header.flags,
                            self.allocator,
                        );
                        defer {
                            for (parsed.headers) |header| {
                                self.allocator.free(header.name);
                                self.allocator.free(header.value);
                            }
                            self.allocator.free(parsed.headers);
                        }

                        try self.parseHeaders(
                            @TypeOf(parsed.headers[0]),
                            parsed.headers,
                            &request_headers,
                            &method_raw,
                            &method_owned,
                            &path_raw,
                            &path_owned,
                            &scheme_raw,
                            &scheme_owned,
                            &authority_raw,
                            &authority_owned,
                        );
                    } else {
                        pending_headers_flags = frame.header.flags;
                        try pending_headers_block.appendSlice(self.allocator, frame.payload);
                        waiting_continuation = true;
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        request_done = true;
                    }
                },
                .continuation => {
                    if (!waiting_continuation) return error.ProtocolError;
                    if (request_stream_id == null or frame.header.stream_id != request_stream_id.?) continue;

                    try pending_headers_block.appendSlice(self.allocator, frame.payload);
                    if ((frame.header.flags & 0x04) != 0) {
                        const parsed = try h2stream.parseHeadersFramePayload(
                            &stream_manager,
                            pending_headers_block.items,
                            pending_headers_flags,
                            self.allocator,
                        );
                        defer {
                            for (parsed.headers) |header| {
                                self.allocator.free(header.name);
                                self.allocator.free(header.value);
                            }
                            self.allocator.free(parsed.headers);
                        }

                        try self.parseHeaders(
                            @TypeOf(parsed.headers[0]),
                            parsed.headers,
                            &request_headers,
                            &method_raw,
                            &method_owned,
                            &path_raw,
                            &path_owned,
                            &scheme_raw,
                            &scheme_owned,
                            &authority_raw,
                            &authority_owned,
                        );

                        pending_headers_block.clearRetainingCapacity();
                        waiting_continuation = false;

                        if ((pending_headers_flags & 0x01) != 0) {
                            request_done = true;
                        }
                    }
                },
                .data => {
                    if (request_stream_id == null) continue;
                    // Send RST_STREAM for concurrent streams (single-stream server).
                    if (frame.header.stream_id != request_stream_id.?) {
                        const rst_frame = h2stream.buildRstStreamFrame(frame.header.stream_id, .refused_stream);
                        try conn.writer.writeAll(&rst_frame);
                        continue;
                    }

                    var data_slice = frame.payload;
                    if ((frame.header.flags & 0x08) != 0) {
                        if (frame.payload.len == 0) return error.ProtocolError;
                        const pad_len = frame.payload[0];
                        if (frame.payload.len < @as(usize, pad_len) + 1) return error.ProtocolError;
                        data_slice = frame.payload[1 .. frame.payload.len - pad_len];
                    }

                    if (request_body.items.len + data_slice.len > self.config.max_body_size) {
                        return error.RequestTooLarge;
                    }
                    try request_body.appendSlice(self.allocator, data_slice);

                    if (data_slice.len > 0) {
                        // Replenish stream and connection receive windows as DATA is consumed.
                        const window_increment: u31 = @intCast(data_slice.len);
                        const window_update = h2stream.buildWindowUpdatePayload(window_increment);

                        try conn.writeFrame(.{
                            .length = @intCast(window_update.len),
                            .frame_type = .window_update,
                            .flags = 0,
                            .stream_id = request_stream_id.?,
                        }, &window_update);

                        try conn.writeFrame(.{
                            .length = @intCast(window_update.len),
                            .frame_type = .window_update,
                            .flags = 0,
                            .stream_id = 0,
                        }, &window_update);
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        request_done = true;
                    }
                },
                .rst_stream => {
                    if (request_stream_id != null and frame.header.stream_id == request_stream_id.?) {
                        request_done = true;
                    }
                },
                .goaway => {
                    return;
                },
                .window_update, .priority, .push_promise => {},
                _ => {},
            }
        }

        if (waiting_continuation) return error.ProtocolError;

        const stream_id = request_stream_id orelse return error.ProtocolError;

        const scheme = if (scheme_raw.len == 0) "http" else scheme_raw;
        const path = if (path_raw.len == 0) "/" else path_raw;
        const authority = authority_raw orelse request_headers.get(HeaderName.HOST) orelse self.config.host;
        if (request_headers.get(HeaderName.HOST) == null) {
            try request_headers.append(HeaderName.HOST, authority);
        }

        const method = types.Method.fromString(method_raw) orelse .GET;

        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, authority, path });
        defer self.allocator.free(url);

        var req = try Request.init(self.allocator, method, url);
        defer req.deinit();
        req.version = .HTTP_2;

        req.headers.deinit();
        req.headers = Headers.init(self.allocator);
        for (request_headers.entries.items) |entry| {
            try req.headers.append(entry.name, entry.value);
        }

        if (request_body.items.len > 0) {
            req.body = try self.allocator.dupe(u8, request_body.items);
            req.body_owned = true;
        }

        var response = self.executeServerRequest(&req) catch {
            var internal = Response.init(self.allocator, status_mod.StatusCode.INTERNAL_SERVER_ERROR);
            defer internal.deinit();
            internal.version = .HTTP_2;
            try self.sendHttp2Response(&conn, &stream_manager, stream_id, &internal);
            const goaway_frame = try h2stream.buildGoawayFrame(stream_id, .internal_error, null, self.allocator);
            defer self.allocator.free(goaway_frame);
            try conn.writer.writeAll(goaway_frame);
            return;
        };
        defer response.deinit();
        response.version = .HTTP_2;

        try self.sendHttp2Response(&conn, &stream_manager, stream_id, &response);

        // Send GOAWAY to signal clean shutdown.
        const goaway_frame = try h2stream.buildGoawayFrame(stream_id, .no_error, null, self.allocator);
        defer self.allocator.free(goaway_frame);
        try conn.writer.writeAll(goaway_frame);

        // Give the peer time to drain queued bytes before teardown.
        sock.shutdownWrite() catch {};
        sleepMs(25);
    }

    fn sendHttp2Response(
        self: *Self,
        conn: *http.Http2Connection,
        stream_manager: *h2stream.StreamManager,
        stream_id: u31,
        response: *Response,
    ) !void {
        try self.ensureContentLengthHeader(response);

        var response_headers = std.ArrayList(hpack.HeaderEntry).empty;
        defer response_headers.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| {
                self.allocator.free(name);
            }
            owned_header_names.deinit(self.allocator);
        }

        var status_buf: [8]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{response.status.code});
        try response_headers.append(self.allocator, .{ .name = ":status", .value = status_str });

        for (response.headers.entries.items) |entry| {
            if (common.isConnectionSpecificHeader(entry.name)) continue;
            if (entry.name.len > 0 and entry.name[0] == ':') continue;

            const lowered = try common.dupLowerAscii(self.allocator, entry.name);
            try owned_header_names.append(self.allocator, lowered);
            try response_headers.append(self.allocator, .{ .name = lowered, .value = entry.value });
        }

        const has_body = response.body != null and response.body.?.len > 0;
        const max_frame_size: u32 = @max(conn.peer_settings.max_frame_size, 16 * 1024);

        const headers_frames = try h2stream.buildHeadersAndContinuations(
            stream_manager,
            stream_id,
            response_headers.items,
            null,
            max_frame_size,
            !has_body,
            self.allocator,
        );
        defer self.allocator.free(headers_frames);

        try conn.writer.writeAll(headers_frames);

        if (has_body) {
            const body = response.body.?;
            const data_max_frame_size: usize = @intCast(max_frame_size);

            var offset: usize = 0;
            while (offset < body.len) {
                const chunk_len = @min(body.len - offset, data_max_frame_size);
                const is_last = offset + chunk_len == body.len;
                try conn.writeFrame(.{
                    .length = @intCast(chunk_len),
                    .frame_type = .data,
                    .flags = if (is_last) 0x01 else 0,
                    .stream_id = stream_id,
                }, body[offset .. offset + chunk_len]);
                offset += chunk_len;
            }
        }
    }

    /// Sends HTTP/2 trailers for a stream.
    /// Trailers are sent as a HEADERS frame with END_STREAM flag set.
    pub fn sendHttp2Trailers(
        self: *Self,
        conn: *http.Http2Connection,
        stream_manager: *h2stream.StreamManager,
        stream_id: u31,
        trailer_headers: *const Headers,
    ) !void {
        var hpack_entries = std.ArrayList(hpack.HeaderEntry).empty;
        defer hpack_entries.deinit(self.allocator);

        var owned_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_names.items) |name| {
                self.allocator.free(name);
            }
            owned_names.deinit(self.allocator);
        }

        for (trailer_headers.entries.items) |entry| {
            if (common.isConnectionSpecificHeader(entry.name)) continue;
            if (entry.name.len > 0 and entry.name[0] == ':') continue;

            const lowered = try common.dupLowerAscii(self.allocator, entry.name);
            try owned_names.append(self.allocator, lowered);
            try hpack_entries.append(self.allocator, .{ .name = lowered, .value = entry.value });
        }

        const max_frame_size: u32 = @max(conn.peer_settings.max_frame_size, 16 * 1024);

        const headers_frames = try h2stream.buildHeadersAndContinuations(
            stream_manager,
            stream_id,
            hpack_entries.items,
            null,
            max_frame_size,
            true, // END_STREAM
            self.allocator,
        );
        defer self.allocator.free(headers_frames);

        try conn.writer.writeAll(headers_frames);
    }

    /// Sends an HTTP/2 PUSH_PROMISE frame to the client, then sends the
    /// promised response on the new server-initiated stream.
    ///
    /// Returns the promised stream ID on success.
    pub fn pushPromise(
        self: *Self,
        conn: *http.Http2Connection,
        stream_manager: *h2stream.StreamManager,
        original_stream_id: u31,
        method: types.Method,
        path: []const u8,
        promise_headers: ?[]const hpack.HeaderEntry,
    ) !u31 {
        if (!self.config.enable_push) return error.PushDisabled;

        var promised_stream = try stream_manager.createStream();
        const promised_id = promised_stream.id;
        try promised_stream.open();

        var promise_header_block = std.ArrayList(hpack.HeaderEntry).empty;
        defer promise_header_block.deinit(self.allocator);

        try promise_header_block.append(self.allocator, .{ .name = ":method", .value = method.toString() });
        try promise_header_block.append(self.allocator, .{ .name = ":path", .value = path });
        try promise_header_block.append(self.allocator, .{ .name = ":scheme", .value = "https" });

        if (promise_headers) |extra| {
            for (extra) |h| {
                try promise_header_block.append(self.allocator, h);
            }
        }

        const max_frame_size: u32 = @max(conn.peer_settings.max_frame_size, 16 * 1024);

        var promise_payload = std.ArrayList(u8).empty;
        defer promise_payload.deinit(self.allocator);

        const encoded_headers = try h2stream.hpack.encodeHeaders(
            &stream_manager.hpack_ctx,
            promise_header_block.items,
            self.allocator,
        );
        defer self.allocator.free(encoded_headers);

        const promised_id_buf: [4]u8 = .{
            @intCast((promised_id >> 24) & 0x7F),
            @intCast((promised_id >> 16) & 0xFF),
            @intCast((promised_id >> 8) & 0xFF),
            @intCast(promised_id & 0xFF),
        };
        try promise_payload.appendSlice(self.allocator, &promised_id_buf);
        try promise_payload.appendSlice(self.allocator, encoded_headers);

        const max_fragment: usize = if (max_frame_size > 9) @intCast(max_frame_size - 9) else 0;

        if (promise_payload.items.len <= max_fragment) {
            const frame_header = http.Http2FrameHeader{
                .length = @intCast(promise_payload.items.len),
                .frame_type = .push_promise,
                .flags = 0x04,
                .stream_id = original_stream_id,
            };
            const hdr = frame_header.serialize();
            try conn.writer.writeAll(&hdr);
            try conn.writer.writeAll(promise_payload.items);
        } else {
            const first_chunk_len = @min(promise_payload.items.len, max_fragment);
            {
                const frame_header = http.Http2FrameHeader{
                    .length = @intCast(first_chunk_len),
                    .frame_type = .push_promise,
                    .flags = 0,
                    .stream_id = original_stream_id,
                };
                const hdr = frame_header.serialize();
                try conn.writer.writeAll(&hdr);
                try conn.writer.writeAll(promise_payload.items[0..first_chunk_len]);
            }

            var offset = first_chunk_len;
            while (offset < promise_payload.items.len) {
                const chunk_len = @min(promise_payload.items.len - offset, max_fragment);
                const is_last = (offset + chunk_len) == promise_payload.items.len;
                const cont_flags: u8 = if (is_last) 0x04 else 0;

                const frame_header = http.Http2FrameHeader{
                    .length = @intCast(chunk_len),
                    .frame_type = .continuation,
                    .flags = cont_flags,
                    .stream_id = original_stream_id,
                };
                const hdr = frame_header.serialize();
                try conn.writer.writeAll(&hdr);
                try conn.writer.writeAll(promise_payload.items[offset .. offset + chunk_len]);
                offset += chunk_len;
            }
        }

        promised_stream.sendEndStream();

        return promised_id;
    }

    fn handleHttp3Transaction(self: *Self, peer_addr: net.Address, first_datagram: []const u8) !void {
        var control_stream_payload = std.ArrayList(u8).empty;
        defer control_stream_payload.deinit(self.allocator);

        var request_stream_payload = std.ArrayList(u8).empty;
        defer request_stream_payload.deinit(self.allocator);

        var request_stream_id: ?u64 = null;
        var request_done = false;
        var client_cid: ?quic.ConnectionId = null;

        // HTTP/3 flow control state
        var conn_max_data: u64 = 10 * 1024 * 1024; // 10 MB default
        var stream_max_data: u64 = 1024 * 1024; // 1 MB default per stream

        var recv_buf: [64 * 1024]u8 = undefined;
        var packet_data: []const u8 = first_datagram;

        while (true) {
            const decoded = try decodeHttp3IncomingDatagram(packet_data);
            if (decoded.client_scid) |cid| {
                client_cid = cid;
            }

            if (decoded.stream_id == 2) {
                try control_stream_payload.appendSlice(self.allocator, decoded.data);
            } else if ((decoded.stream_id & 0x03) == 0) {
                request_stream_id = decoded.stream_id;
                try request_stream_payload.appendSlice(self.allocator, decoded.data);
                if (decoded.fin) {
                    request_done = true;
                }
            }

            if (request_done) break;

            const incoming = self.udp_socket.?.recvFrom(&recv_buf) catch return error.ProtocolError;
            packet_data = recv_buf[0..incoming.n];
        }

        if (control_stream_payload.items.len > 0) {
            // Parse control stream frames, extracting flow control values
            var cs_offset: usize = 0;
            // Skip stream type byte
            if (control_stream_payload.items.len > 0) {
                const st = try http.decodeVarInt(control_stream_payload.items);
                cs_offset = st.len;
            }
            var saw_settings = false;
            while (cs_offset < control_stream_payload.items.len) {
                const frame = try http.Http3FrameHeader.decode(control_stream_payload.items[cs_offset..]);
                cs_offset += frame.len;
                const plen: usize = @intCast(frame.header.length);
                if (control_stream_payload.items.len < cs_offset + plen) break;
                const payload = control_stream_payload.items[cs_offset .. cs_offset + plen];
                cs_offset += plen;

                if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.settings)) {
                    _ = try http.parseHttp3SettingsPayload(payload);
                    saw_settings = true;
                } else if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.max_data)) {
                    if (payload.len > 0) {
                        const val = try http.decodeVarInt(payload);
                        conn_max_data = val.value;
                    }
                } else if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.max_stream_data)) {
                    if (payload.len > 0) {
                        const sid = try http.decodeVarInt(payload);
                        const data_limit = try http.decodeVarInt(payload[sid.len..]);
                        stream_max_data = data_limit.value;
                    }
                }
            }
        }

        const stream_id = request_stream_id orelse return error.ProtocolError;
        const dst_cid = client_cid orelse return error.ProtocolError;

        var request_headers = Headers.init(self.allocator);
        defer request_headers.deinit();

        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        var method_raw: []const u8 = "GET";
        var method_owned = false;
        defer if (method_owned) self.allocator.free(method_raw);

        var path_raw: []const u8 = "/";
        var path_owned = false;
        defer if (path_owned) self.allocator.free(path_raw);

        var scheme_raw: []const u8 = "http";
        var scheme_owned = false;
        defer if (scheme_owned) self.allocator.free(scheme_raw);

        var authority_raw: ?[]const u8 = null;
        var authority_owned = false;
        defer if (authority_owned and authority_raw != null) self.allocator.free(authority_raw.?);

        var qpack_ctx = qpack.QpackContext.initWithCapacity(
            self.allocator,
            common.clampU64ToUsize(self.config.http3_settings.qpack_max_table_capacity),
        );
        defer qpack_ctx.deinit();

        var offset: usize = 0;
        while (offset < request_stream_payload.items.len) {
            const frame = try http.Http3FrameHeader.decode(request_stream_payload.items[offset..]);
            offset += frame.len;

            const payload_len: usize = @intCast(frame.header.length);
            if (request_stream_payload.items.len < offset + payload_len) return error.ProtocolError;

            const frame_payload = request_stream_payload.items[offset .. offset + payload_len];
            offset += payload_len;

            if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.headers)) {
                const decoded_headers = try qpack.decodeHeaders(&qpack_ctx, frame_payload, self.allocator);
                defer {
                    for (decoded_headers) |header| {
                        self.allocator.free(header.name);
                        self.allocator.free(header.value);
                    }
                    self.allocator.free(decoded_headers);
                }

                try self.parseHeaders(
                    @TypeOf(decoded_headers[0]),
                    decoded_headers,
                    &request_headers,
                    &method_raw,
                    &method_owned,
                    &path_raw,
                    &path_owned,
                    &scheme_raw,
                    &scheme_owned,
                    &authority_raw,
                    &authority_owned,
                );
            } else if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.data)) {
                if (request_body.items.len + frame_payload.len > self.config.max_body_size) {
                    return error.RequestTooLarge;
                }
                try request_body.appendSlice(self.allocator, frame_payload);
            }
        }

        const scheme = if (scheme_raw.len == 0) "http" else scheme_raw;
        const path = if (path_raw.len == 0) "/" else path_raw;
        const authority = authority_raw orelse request_headers.get(HeaderName.HOST) orelse self.config.host;
        if (request_headers.get(HeaderName.HOST) == null) {
            try request_headers.append(HeaderName.HOST, authority);
        }

        const method = types.Method.fromString(method_raw) orelse .GET;

        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, authority, path });
        defer self.allocator.free(url);

        var req = try Request.init(self.allocator, method, url);
        defer req.deinit();
        req.version = .HTTP_3;

        req.headers.deinit();
        req.headers = Headers.init(self.allocator);
        for (request_headers.entries.items) |entry| {
            try req.headers.append(entry.name, entry.value);
        }

        if (request_body.items.len > 0) {
            req.body = try self.allocator.dupe(u8, request_body.items);
            req.body_owned = true;
        }

        var response = self.executeServerRequest(&req) catch {
            // Send CONNECTION_CLOSE (application) on unrecoverable handler error
            self.sendHttp3ConnectionCloseApp(peer_addr, dst_cid, @intFromEnum(http.Http3ErrorCode.internal_error), "handler error") catch {};
            var internal = Response.init(self.allocator, status_mod.StatusCode.INTERNAL_SERVER_ERROR);
            defer internal.deinit();
            internal.version = .HTTP_3;
            try self.sendHttp3Response(peer_addr, dst_cid, stream_id, &internal, conn_max_data, stream_max_data);
            return;
        };
        defer response.deinit();
        response.version = .HTTP_3;

        try self.sendHttp3Response(peer_addr, dst_cid, stream_id, &response, conn_max_data, stream_max_data);
    }

    fn sendHttp3Response(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        request_stream_id: u64,
        response: *Response,
        conn_max_data: u64,
        stream_max_data: u64,
    ) !void {
        try self.ensureContentLengthHeader(response);

        var qpack_ctx = qpack.QpackContext.initWithCapacity(
            self.allocator,
            common.clampU64ToUsize(self.config.http3_settings.qpack_max_table_capacity),
        );
        defer qpack_ctx.deinit();

        var response_headers = std.ArrayList(qpack.HeaderEntry).empty;
        defer response_headers.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| {
                self.allocator.free(name);
            }
            owned_header_names.deinit(self.allocator);
        }

        var status_buf: [8]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{response.status.code});
        try response_headers.append(self.allocator, .{ .name = ":status", .value = status_str });

        for (response.headers.entries.items) |entry| {
            if (common.isConnectionSpecificHeader(entry.name)) continue;
            if (entry.name.len > 0 and entry.name[0] == ':') continue;

            const lowered = try common.dupLowerAscii(self.allocator, entry.name);
            try owned_header_names.append(self.allocator, lowered);
            try response_headers.append(self.allocator, .{ .name = lowered, .value = entry.value });
        }

        const encoded_headers = try qpack.encodeHeaders(&qpack_ctx, response_headers.items, self.allocator);
        defer self.allocator.free(encoded_headers);

        var response_stream_payload = std.ArrayList(u8).empty;
        defer response_stream_payload.deinit(self.allocator);
        try http.appendHttp3Frame(&response_stream_payload, self.allocator, .headers, encoded_headers);
        if (response.body) |body| {
            try http.appendHttp3Frame(&response_stream_payload, self.allocator, .data, body);
        }

        var settings_payload = std.ArrayList(u8).empty;
        defer settings_payload.deinit(self.allocator);
        try http.encodeHttp3SettingsPayload(self.config.http3_settings, self.allocator, &settings_payload);

        var control_stream_payload = std.ArrayList(u8).empty;
        defer control_stream_payload.deinit(self.allocator);
        try http.appendVarInt(&control_stream_payload, self.allocator, @intFromEnum(quic.Http3StreamType.control));
        try http.appendHttp3Frame(&control_stream_payload, self.allocator, .settings, settings_payload.items);

        // Send MAX_DATA and MAX_STREAM_DATA to advertise our flow control limits
        {
            var max_data_payload = std.ArrayList(u8).empty;
            defer max_data_payload.deinit(self.allocator);
            try http.appendVarInt(&max_data_payload, self.allocator, conn_max_data);
            try http.appendHttp3Frame(&control_stream_payload, self.allocator, .max_data, max_data_payload.items);
        }
        {
            var max_stream_data_payload = std.ArrayList(u8).empty;
            defer max_stream_data_payload.deinit(self.allocator);
            try http.appendVarInt(&max_stream_data_payload, self.allocator, request_stream_id);
            try http.appendVarInt(&max_stream_data_payload, self.allocator, stream_max_data);
            try http.appendHttp3Frame(&control_stream_payload, self.allocator, .max_stream_data, max_stream_data_payload.items);
        }

        const server_cid = quic.ConnectionId.random();

        const control_packet = try buildHttp3Datagram(
            self.allocator,
            dst_cid,
            server_cid,
            1,
            3,
            0,
            false,
            control_stream_payload.items,
        );
        defer self.allocator.free(control_packet);

        const response_packet = try buildHttp3Datagram(
            self.allocator,
            dst_cid,
            server_cid,
            2,
            request_stream_id,
            0,
            true,
            response_stream_payload.items,
        );
        defer self.allocator.free(response_packet);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, control_packet);
        _ = try udp.sendTo(peer_addr, response_packet);
    }

    /// Sends an HTTP/3 GOAWAY frame on the control stream.
    pub fn sendHttp3Goaway(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        stream_id: u64,
    ) !void {
        var goaway_payload = std.ArrayList(u8).empty;
        defer goaway_payload.deinit(self.allocator);
        try http.appendVarInt(&goaway_payload, self.allocator, stream_id);

        var control_stream_payload = std.ArrayList(u8).empty;
        defer control_stream_payload.deinit(self.allocator);
        try http.appendVarInt(&control_stream_payload, self.allocator, @intFromEnum(quic.Http3StreamType.control));
        try http.appendHttp3Frame(&control_stream_payload, self.allocator, .goaway, goaway_payload.items);

        const server_cid = quic.ConnectionId.random();
        const packet = try buildHttp3Datagram(
            self.allocator,
            dst_cid,
            server_cid,
            1,
            3,
            0,
            false,
            control_stream_payload.items,
        );
        defer self.allocator.free(packet);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, packet);
    }

    /// Sends a QUIC CONNECTION_CLOSE (application, type 0x1d) frame.
    pub fn sendHttp3ConnectionCloseApp(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        error_code: u64,
        reason: []const u8,
    ) !void {
        var close_buf: [128]u8 = undefined;
        const frame = quic.ConnectionCloseFrame{
            .error_code = error_code,
            .reason_phrase = reason,
        };
        const frame_len = try frame.encode(true, &close_buf);

        var packet = try buildQuicInitialPacket(self.allocator, dst_cid, quic.ConnectionId.random(), 0, close_buf[0..frame_len]);
        defer packet.deinit(self.allocator);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, packet.items);
    }

    /// Sends a QUIC RESET_STREAM frame to cancel a stream.
    pub fn sendHttp3ResetStream(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        stream_id: u64,
        error_code: u64,
        final_size: u64,
    ) !void {
        var frame_buf: [64]u8 = undefined;
        const frame = quic.ResetStreamFrame{
            .stream_id = stream_id,
            .error_code = error_code,
            .final_size = final_size,
        };
        const frame_len = try frame.encode(&frame_buf);

        var packet = try buildQuicInitialPacket(self.allocator, dst_cid, quic.ConnectionId.random(), 0, frame_buf[0..frame_len]);
        defer packet.deinit(self.allocator);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, packet.items);
    }

    /// Sends a QUIC STOP_SENDING frame to tell the peer to stop sending on a stream.
    pub fn sendHttp3StopSending(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        stream_id: u64,
        error_code: u64,
    ) !void {
        var frame_buf: [64]u8 = undefined;
        const frame = quic.StopSendingFrame{
            .stream_id = stream_id,
            .error_code = error_code,
        };
        const frame_len = try frame.encode(&frame_buf);

        var packet = try buildQuicInitialPacket(self.allocator, dst_cid, quic.ConnectionId.random(), 0, frame_buf[0..frame_len]);
        defer packet.deinit(self.allocator);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, packet.items);
    }

    /// Sends a QUIC CONNECTION_CLOSE (transport, type 0x1c) frame.
    pub fn sendHttp3ConnectionCloseTransport(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        error_code: u64,
        frame_type: u64,
        reason: []const u8,
    ) !void {
        var close_buf: [128]u8 = undefined;
        const frame = quic.ConnectionCloseFrame{
            .error_code = error_code,
            .frame_type = frame_type,
            .reason_phrase = reason,
        };
        const frame_len = try frame.encode(false, &close_buf);

        var packet = try buildQuicInitialPacket(self.allocator, dst_cid, quic.ConnectionId.random(), 0, close_buf[0..frame_len]);
        defer packet.deinit(self.allocator);

        const udp = if (self.udp_socket) |*u| u else return error.ProtocolError;
        _ = try udp.sendTo(peer_addr, packet.items);
    }

    fn executeServerRequest(self: *Self, req: *Request) !Response {
        dbg.log("SERVER", "executeRequest {s} {s}", .{ req.method.toString(), req.uri.path });
        var ctx = Context.init(self.allocator, req);
        ctx.server = self;
        defer ctx.deinit();

        for (self.pre_route_hooks.items) |hook| {
            try hook(&ctx);
        }

        var suppress_body = false;
        var route_result = self.router.find(req.method, req.uri.path);

        // If HEAD is not explicitly registered, fall back to GET semantics
        // and suppress the response body.
        if (route_result == null and req.method == .HEAD) {
            route_result = self.router.find(.GET, req.uri.path);
            suppress_body = route_result != null;
        }

        if (route_result) |r| {
            for (r.params) |p| {
                try ctx.params.put(p.name, p.value);
            }
        }

        const FallbackHandler = struct {
            server: *Self,
            route_result: @TypeOf(self.router.find(.GET, "/")),
            suppress_body: bool,

            fn handle(c: *Context) anyerror!Response {
                const self_ptr = @This();
                const s = c.data.get("__fallback_state") orelse return error.MissingFallbackState;
                const state: *const self_ptr = @ptrCast(@alignCast(s));

                if (state.route_result) |r| {
                    return r.handler(c);
                }

                var allow_methods: [16]types.Method = undefined;
                const allow_count = state.server.router.allowedMethods(c.request.uri.path, &allow_methods);

                if (c.request.method == .OPTIONS and allow_count > 0) {
                    var response = Response.init(state.server.allocator, status_mod.StatusCode.NO_CONTENT);
                    try state.server.setAllowHeader(&response.headers, allow_methods[0..allow_count]);
                    return response;
                } else if (allow_count > 0) {
                    var response = Response.init(state.server.allocator, status_mod.StatusCode.METHOD_NOT_ALLOWED);
                    try state.server.setAllowHeader(&response.headers, allow_methods[0..allow_count]);
                    return response;
                } else if (state.server.global_handler) |global_handler| {
                    return global_handler(c);
                } else {
                    return Response.init(state.server.allocator, status_mod.StatusCode.NOT_FOUND);
                }
            }
        };

        var fallback = FallbackHandler{
            .server = self,
            .route_result = route_result,
            .suppress_body = suppress_body,
        };
        try ctx.data.put("__fallback_state", @ptrCast(&fallback));
        defer _ = ctx.data.remove("__fallback_state");

        var response = try self.executeMiddleware(&ctx, FallbackHandler.handle);

        if (suppress_body or req.method == .HEAD) {
            if (response.body_owned) {
                if (response.body) |body| self.allocator.free(body);
                response.body_owned = false;
            }
            response.body = null;
        }

        return response;
    }

    /// Sends an error response.
    fn sendError(self: *Self, socket: *Socket, code: u16) !void {
        dbg.log("SERVER", "sendError status={d}", .{code});
        var resp = Response.init(self.allocator, code);
        defer resp.deinit();

        try self.ensureContentLengthHeader(&resp);

        const formatted = try http.formatResponse(&resp, self.allocator);
        defer self.allocator.free(formatted);

        try socket.sendAll(formatted);
    }

    fn ensureContentLengthHeader(self: *Self, response: *Response) !void {
        _ = self;
        if (response.headers.get(HeaderName.CONTENT_LENGTH) != null) return;
        if (response.headers.isChunked()) return;
        if ((response.status.code >= 100 and response.status.code < 200) or
            response.status.code == status_mod.StatusCode.NO_CONTENT or
            response.status.code == status_mod.StatusCode.NOT_MODIFIED)
        {
            return;
        }

        const body_len: usize = if (response.body) |b| b.len else 0;
        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
        try response.headers.set(HeaderName.CONTENT_LENGTH, len_str);
    }

    /// Sets the `Allow` header for automatic OPTIONS and 405 responses.
    fn setAllowHeader(self: *Self, headers: *Headers, methods: []const types.Method) !void {
        var allow = std.ArrayList(u8).empty;
        defer allow.deinit(self.allocator);
        const writer = list_writer.init(self.allocator, &allow);

        var first = true;
        var has_options = false;

        for (methods) |m| {
            if (m == .OPTIONS) has_options = true;
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.writeAll(m.toString());
        }

        if (!has_options) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("OPTIONS");
        }

        try headers.set("Allow", allow.items);
    }

    const MiddlewareExecState = struct {
        server: *Self,
        route_handler: Handler,
        index: usize = 0,
    };

    fn executeMiddleware(self: *Self, ctx: *Context, route_handler: Handler) !Response {
        var state = MiddlewareExecState{
            .server = self,
            .route_handler = route_handler,
        };
        try ctx.data.put("__mw_exec_state", @ptrCast(&state));
        defer _ = ctx.data.remove("__mw_exec_state");

        return middlewareNext(ctx);
    }

    fn middlewareNext(ctx: *Context) anyerror!Response {
        const raw = ctx.data.get("__mw_exec_state") orelse return error.MissingMiddlewareState;
        const state: *MiddlewareExecState = @ptrCast(@alignCast(raw));

        if (state.index < state.server.middleware.items.len) {
            const mw = state.server.middleware.items[state.index];
            state.index += 1;
            return mw.handler(ctx, middlewareNext);
        }

        return state.route_handler(ctx);
    }
};

const Http3IncomingDatagram = struct {
    stream_id: u64,
    fin: bool,
    data: []const u8,
    client_scid: ?quic.ConnectionId = null,
};

fn decodeHttp3IncomingDatagram(datagram: []const u8) !Http3IncomingDatagram {
    if (datagram.len == 0) return error.ProtocolError;

    var offset: usize = 0;
    var client_scid: ?quic.ConnectionId = null;

    if ((datagram[0] & 0x80) != 0) {
        const long_header = try quic.LongHeader.decode(datagram);
        offset = long_header.len;
        if (long_header.header.scid.len > 0) {
            client_scid = long_header.header.scid;
        }
    } else {
        const short_header = try quic.ShortHeader.decode(datagram, 8);
        offset = short_header.len;
    }

    const packet_number = try quic.decodeVarInt(datagram[offset..]);
    _ = packet_number.value;
    offset += packet_number.len;

    if (offset >= datagram.len) return error.ProtocolError;
    if (!quic.FrameType.isStream(@as(u64, datagram[offset]))) return error.ProtocolError;

    const stream = try quic.StreamFrame.decode(datagram[offset..]);
    if (stream.len != datagram[offset..].len) return error.ProtocolError;

    return .{
        .stream_id = stream.frame.stream_id,
        .fin = stream.frame.fin,
        .data = stream.frame.data,
        .client_scid = client_scid,
    };
}

fn buildQuicInitialPacket(
    allocator: Allocator,
    dst_cid: quic.ConnectionId,
    scid: quic.ConnectionId,
    packet_number: u64,
    frame_payload: []const u8,
) !std.ArrayList(u8) {
    var packet = std.ArrayList(u8).empty;
    errdefer packet.deinit(allocator);

    var header_buf: [128]u8 = undefined;
    const header_len = try (quic.LongHeader{
        .packet_type = .initial,
        .version = .v1,
        .dcid = dst_cid,
        .scid = scid,
    }).encode(&header_buf);
    try packet.appendSlice(allocator, header_buf[0..header_len]);

    var pn_buf: [8]u8 = undefined;
    const pn_len = try quic.encodeVarInt(packet_number, &pn_buf);
    try packet.appendSlice(allocator, pn_buf[0..pn_len]);
    try packet.appendSlice(allocator, frame_payload);

    return packet;
}

fn buildHttp3Datagram(
    allocator: Allocator,
    dcid: quic.ConnectionId,
    scid: quic.ConnectionId,
    packet_number: u64,
    stream_id: u64,
    stream_offset: u64,
    fin: bool,
    payload: []const u8,
) ![]u8 {
    const frame_storage = try allocator.alloc(u8, payload.len + 64);
    defer allocator.free(frame_storage);

    const stream_frame = quic.StreamFrame{
        .stream_id = stream_id,
        .offset = stream_offset,
        .length = @intCast(payload.len),
        .fin = fin,
        .data = payload,
    };
    const frame_len = try stream_frame.encode(frame_storage);

    var packet = try buildQuicInitialPacket(allocator, dcid, scid, packet_number, frame_storage[0..frame_len]);
    defer packet.deinit(allocator);
    return packet.toOwnedSlice(allocator);
}

fn trailerHeaderNames(allocator: Allocator, headers: *const Headers) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const writer = list_writer.init(allocator, &out);

    var first = true;
    for (headers.entries.items) |h| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll(h.name);
    }

    return out.toOwnedSlice(allocator);
}

fn buildStaticEtag(allocator: Allocator, path: []const u8, stat: anytype) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);

    const size_u64: u64 = @intCast(stat.size);
    hasher.update(mem.asBytes(&size_u64));

    const Stat = @TypeOf(stat);
    if (@hasField(Stat, "mtime")) {
        const mtime = stat.mtime;
        hasher.update(mem.asBytes(&mtime));
    } else if (@hasField(Stat, "mtime_ns")) {
        const mtime_ns = stat.mtime_ns;
        hasher.update(mem.asBytes(&mtime_ns));
    }

    const digest = hasher.final();
    return std.fmt.allocPrint(allocator, "W/\"{x}-{x}\"", .{ size_u64, digest });
}

fn normalizeEtagToken(token: []const u8) []const u8 {
    var trimmed = mem.trim(u8, token, " \t");
    if (mem.startsWith(u8, trimmed, "W/")) {
        trimmed = mem.trim(u8, trimmed[2..], " \t");
    }
    return trimmed;
}

fn ifNoneMatchMatches(if_none_match_header: []const u8, etag: []const u8) bool {
    const normalized_target = normalizeEtagToken(etag);
    var values = mem.splitScalar(u8, if_none_match_header, ',');

    while (values.next()) |raw_value| {
        const token = mem.trim(u8, raw_value, " \t");
        if (token.len == 0) continue;
        if (mem.eql(u8, token, "*")) return true;
        if (mem.eql(u8, normalizeEtagToken(token), normalized_target)) return true;
    }

    return false;
}

test "Server initialization" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8080), server.config.port);
    try std.testing.expectEqualStrings("127.0.0.1", server.config.host);
    try std.testing.expectEqual(@as(u32, 1000), server.config.max_connections);
    try std.testing.expectEqual(@as(u64, 30_000), server.config.request_timeout_ms);
    try std.testing.expectEqual(@as(u64, 60_000), server.config.keep_alive_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), server.config.threads);
    try std.testing.expect(server.config.keep_alive);
}

test "Context response helpers" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/test");
    defer req.deinit();

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    _ = ctx.status(201);
    try std.testing.expectEqual(@as(u16, 201), ctx.response.status_code);
}

test "Context fileAs helper compile check" {
    const file_as_ptr: *const fn (*Context, []const u8, []const u8) anyerror!Response = Context.fileAs;
    _ = file_as_ptr;
}

test "Context fileWithOptions helper compile check" {
    const file_with_options_ptr: *const fn (*Context, []const u8, FileResponseOptions) anyerror!Response = Context.fileWithOptions;
    _ = file_with_options_ptr;
}

test "Context download helper compile check" {
    const download_ptr: *const fn (*Context, []const u8, ?[]const u8) anyerror!Response = Context.download;
    _ = download_ptr;
}

test "Context noContent helper" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/empty");
    defer req.deinit();

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    var response = try ctx.noContent();
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 204), response.status.code);
    try std.testing.expect(response.body == null);
}

test "If-None-Match helper supports weak tags and lists" {
    try std.testing.expect(ifNoneMatchMatches("W/\"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatchMatches("\"def\", W/\"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatchMatches("*", "\"abc\""));
    try std.testing.expect(!ifNoneMatchMatches("\"def\"", "\"abc\""));
}

test "Server with config" {
    const allocator = std.testing.allocator;
    var server = Server.initWithConfig(allocator, .{
        .host = "0.0.0.0",
        .port = 3000,
    });
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 3000), server.config.port);
    try std.testing.expectEqualStrings("0.0.0.0", server.config.host);
}

test "Context query parsing" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/search?q=zig&lang=en");
    defer req.deinit();

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("zig", ctx.query("q").?);
    try std.testing.expectEqualStrings("en", ctx.query("lang").?);
    try std.testing.expect(ctx.query("missing") == null);
}

test "Context cookie helpers" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/");
    defer req.deinit();
    try req.headers.set(HeaderName.COOKIE, "session=abc123; theme=dark");

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("abc123", ctx.cookie("session").?);
    try std.testing.expectEqualStrings("dark", ctx.cookie("theme").?);
    try std.testing.expect(ctx.cookie("missing") == null);

    try ctx.setCookie("session", "next", .{ .path = "/", .http_only = true, .same_site = .lax });
    const set_cookie = ctx.response.headers.get(HeaderName.SET_COOKIE).?;
    try std.testing.expect(mem.indexOf(u8, set_cookie, "session=next") != null);

    try ctx.removeCookie("session", .{ .path = "/" });
    const all_set_cookies = try ctx.response.headers.getAll(HeaderName.SET_COOKIE, allocator);
    defer allocator.free(all_set_cookies);
    try std.testing.expect(all_set_cookies.len >= 2);
}

test "Context auth and media helpers" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .POST, "/api");
    defer req.deinit();

    try req.headers.set(HeaderName.AUTHORIZATION, "Bearer demo-token");
    try req.headers.set(HeaderName.CONTENT_TYPE, "application/json; charset=utf-8");
    try req.headers.set(HeaderName.ACCEPT, "application/json, text/*;q=0.8");

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("Bearer demo-token", ctx.authorization().?);
    try std.testing.expectEqualStrings("demo-token", ctx.bearerToken().?);
    try std.testing.expect(ctx.hasContentType("application/json"));
    try std.testing.expect(ctx.isJson());
    try std.testing.expect(!ctx.isFormUrlEncoded());
    try std.testing.expect(ctx.acceptsJson());
    try std.testing.expect(ctx.accepts("text/plain"));
    try std.testing.expect(!ctx.accepts("image/png"));
}

test "Router allowed methods for path" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    const handler = struct {
        fn h(_: *Context) anyerror!Response {
            return error.TestUnexpectedResult;
        }
    }.h;

    try server.get("/users/:id", handler);
    try server.put("/users/:id", handler);
    try server.delete("/users/:id", handler);

    var methods: [16]types.Method = undefined;
    const count = server.router.allowedMethods("/users/42", &methods);

    try std.testing.expect(count >= 3);

    var has_get = false;
    var has_put = false;
    var has_delete = false;
    for (methods[0..count]) |m| {
        if (m == .GET) has_get = true;
        if (m == .PUT) has_put = true;
        if (m == .DELETE) has_delete = true;
    }

    try std.testing.expect(has_get);
    try std.testing.expect(has_put);
    try std.testing.expect(has_delete);
}

test "Server any() registers all methods" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    const handler = struct {
        fn h(_: *Context) anyerror!Response {
            return error.TestUnexpectedResult;
        }
    }.h;

    try server.any("/wild", handler);

    try std.testing.expect(server.router.find(.GET, "/wild") != null);
    try std.testing.expect(server.router.find(.POST, "/wild") != null);
    try std.testing.expect(server.router.find(.TRACE, "/wild") != null);
    try std.testing.expect(server.router.find(.CONNECT, "/wild") != null);
}

test "Server trace/connect helpers register routes" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    const handler = struct {
        fn h(_: *Context) anyerror!Response {
            return error.TestUnexpectedResult;
        }
    }.h;

    try server.trace("/diag", handler);
    try server.connect("/tunnel", handler);

    try std.testing.expect(server.router.find(.TRACE, "/diag") != null);
    try std.testing.expect(server.router.find(.CONNECT, "/tunnel") != null);
}

fn reserveTcpPort() !struct { listener: TcpListener, port: u16 } {
    const addr = try net.Address.parseIp("127.0.0.1", 0);
    var listener = try TcpListener.init(addr);
    const local = try listener.getLocalAddress();
    return .{ .listener = listener, .port = local.getPort() };
}

fn reserveUdpPort() !struct { socket: UdpSocket, port: u16 } {
    const addr = try net.Address.parseIp("127.0.0.1", 0);
    var socket = try UdpSocket.createForAddress(addr);
    errdefer socket.close();
    try socket.bind(addr);
    const local = try socket.getLocalAddress();
    return .{ .socket = socket, .port = local.getPort() };
}

test "Server port conflict strategy fail for TCP" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var reserved = reserveTcpPort() catch |err| switch (err) {
        error.SetSockOptFailed => return error.SkipZigTest,
        else => return err,
    };
    defer reserved.listener.deinit();

    var server = Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = reserved.port,
        .port_conflict = .fail,
        .max_port_tries = 8,
    });
    defer server.deinit();

    const backlog_u32: u32 = @max(server.config.max_connections, 1);
    const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));

    _ = server.bindTcpListener(backlog) catch |err| {
        try std.testing.expect(err == error.AddressInUse or err == error.BindFailed);
        return;
    };

    return error.TestUnexpectedResult;
}

test "Server port conflict strategy increment for TCP" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var reserved = reserveTcpPort() catch |err| switch (err) {
        error.SetSockOptFailed => return error.SkipZigTest,
        else => return err,
    };
    defer reserved.listener.deinit();

    var server = Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = reserved.port,
        .port_conflict = .increment,
        .max_port_tries = 32,
    });
    defer server.deinit();

    const backlog_u32: u32 = @max(server.config.max_connections, 1);
    const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
    try server.bindTcpListener(backlog);

    try std.testing.expect(server.listener != null);
    try std.testing.expect(server.config.port != reserved.port);
}

test "Server port conflict strategy fail for HTTP/3 UDP" {
    const allocator = std.testing.allocator;

    var reserved = try reserveUdpPort();
    defer reserved.socket.close();

    var server = Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = reserved.port,
        .http3_enabled = true,
        .port_conflict = .fail,
        .max_port_tries = 8,
    });
    defer server.deinit();

    _ = server.bindUdpSocket() catch |err| {
        try std.testing.expect(err == error.AddressInUse or err == error.BindFailed);
        return;
    };

    return error.TestUnexpectedResult;
}

test "Server port conflict strategy increment for HTTP/3 UDP" {
    const allocator = std.testing.allocator;

    var reserved = try reserveUdpPort();
    defer reserved.socket.close();

    var server = Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = reserved.port,
        .http3_enabled = true,
        .port_conflict = .increment,
        .max_port_tries = 32,
    });
    defer server.deinit();

    try server.bindUdpSocket();

    try std.testing.expect(server.udp_socket != null);
    try std.testing.expect(server.config.port != reserved.port);
}

test "Server custom log callback" {
    const allocator = std.testing.allocator;
    const CustomLogger = struct {
        var logged: bool = false;
        fn log_fn(level: LogLevel, message: []const u8) void {
            if (level == .info and std.mem.indexOf(u8, message, "test log message") != null) {
                logged = true;
            }
        }
    };

    const server = Server.initWithConfig(allocator, .{
        .log_fn = CustomLogger.log_fn,
    });
    server.log(.info, "this is a {s} message", .{"test log message"});
    try std.testing.expect(CustomLogger.logged);
}

test "Server with thread pool handles connections" {
    const allocator = std.testing.allocator;
    const Client = @import("../client/client.zig").Client;

    var server = Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .threads = 2,
        .keep_alive = false,
        .log_fn = &struct {
            fn log_fn(_: LogLevel, _: []const u8) void {}
        }.log_fn,
    });
    defer server.deinit();

    const handler = struct {
        fn h(ctx: *Context) anyerror!Response {
            return ctx.text("hello from worker pool");
        }
    }.h;

    try server.get("/hello", handler);

    const thread = try server.listenInBackground();
    defer {
        server.stop();
        thread.join();
    }

    sleepMs(50);

    const port = server.listeningPort();
    var client = Client.initWithConfig(allocator, .{
        .timeouts = .uniform(5000),
        .keep_alive = false,
    });
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/hello", .{port});
    defer allocator.free(url);

    var resp = try client.get(url, .{});
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status.code);
    try std.testing.expectEqualStrings("hello from worker pool", resp.text().?);
}
