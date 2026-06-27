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
const http = @import("../protocol/http.zig");
const hpack = @import("../protocol/hpack.zig");
const h2stream = @import("../protocol/stream.zig");
const qpack = @import("../protocol/qpack.zig");
const quic = @import("../protocol/quic.zig");
const Socket = @import("../net/socket.zig").Socket;
const TcpListener = @import("../net/socket.zig").TcpListener;
const UdpSocket = @import("../net/socket.zig").UdpSocket;
const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;
const common = @import("../util/common.zig");
const list_writer = @import("../util/list_writer.zig");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: i64) void {
    const io = defaultIo();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub const CookieOptions = common.CookieOptions;
pub const SameSite = common.SameSite;

/// Strategy for handling bind conflicts on startup.
pub const PortConflictStrategy = enum {
    /// Fail immediately when the configured port is unavailable.
    fail,
    /// Retry on subsequent ports (`port + 1`, `port + 2`, ...) until a free port is found.
    increment,
};

/// SSE event payload used by `Context.sse`.
pub const SseEvent = struct {
    data: []const u8,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry_ms: ?u32 = null,
};

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
    http2_settings: types.Http2Settings = .{},
    http3_settings: types.Http3Settings = .{},
    log_fn: ?LogFn = null,
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
        const io = defaultIo();
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return self.status(404).text("Not Found");
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
                        _ = self.response.status(304);
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

    /// Sends a redirect response.
    pub fn redirect(self: *Self, url: []const u8, code: u16) !Response {
        _ = self.response.status(code);
        _ = try self.response.header(HeaderName.LOCATION, url);
        return self.response.build();
    }

    /// Sends a 204 No Content response.
    pub fn noContent(self: *Self) !Response {
        _ = self.response.status(204);
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
    running: bool = false,

    const Self = @This();

    /// Creates a server with default configuration.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates a server with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ServerConfig) Self {
        var cfg = config;
        if (cfg.max_connections == 0) cfg.max_connections = 1000;
        if (cfg.max_port_tries == 0) cfg.max_port_tries = 1;
        if (cfg.request_timeout_ms == 0) cfg.request_timeout_ms = 30_000;
        if (cfg.keep_alive_timeout_ms == 0) cfg.keep_alive_timeout_ms = 60_000;

        return .{
            .allocator = allocator,
            .config = cfg,
            .router = Router.init(allocator),
        };
    }

    /// Releases all server resources.
    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.middleware.deinit(self.allocator);
        self.pre_route_hooks.deinit(self.allocator);
        if (self.listener) |*l| l.deinit();
        if (self.udp_socket) |*u| u.close();
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
    pub fn listen(self: *Self) !void {
        if (self.config.http3_enabled) {
            return self.listenHttp3();
        }

        return self.listenTcp();
    }

    /// Spawns a background thread to run the server's listening loop.
    /// The caller is responsible for joining the returned Thread.
    pub fn listenInBackground(self: *Self) !std.Thread {
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
    /// Otherwise, prints to stderr.
    pub fn log(self: *const Self, level: LogLevel, comptime format: []const u8, args: anytype) void {
        if (self.config.log_fn) |log_fn| {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, format, args)) |msg| {
                log_fn(level, msg);
            } else |_| {
                log_fn(level, "[Log format failed or message too long]");
            }
        } else {
            std.debug.print(format, args);
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
            self.config.port = candidate_port;
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
                self.config.port = candidate_port;
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
        const backlog_u32: u32 = @max(self.config.max_connections, 1);
        const backlog: u31 = @intCast(@min(backlog_u32, @as(u32, std.math.maxInt(u31))));
        try self.bindTcpListener(backlog);
        self.running = true;

        self.log(.info, "Server listening on {s}:{d}\n", .{ self.config.host, self.config.port });

        while (self.running) {
            const conn = self.listener.?.accept() catch |err| {
                if (!self.running) break;
                self.log(.err, "Accept error: {}\n", .{err});
                continue;
            };

            self.handleConnection(conn.socket) catch |err| {
                self.log(.err, "Handler error: {}\n", .{err});
            };
        }
    }

    fn listenHttp3(self: *Self) !void {
        try self.bindUdpSocket();
        self.running = true;

        self.log(.info, "Server listening (HTTP/3) on {s}:{d}\n", .{ self.config.host, self.config.port });

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

    /// Stops the server.
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
        if (self.udp_socket) |*u| {
            u.close();
            self.udp_socket = null;
        }
    }

    /// Handles a single connection.
    fn handleConnection(self: *Self, socket: Socket) !void {
        if (self.config.http2_enabled) {
            return self.handleHttp2Connection(socket);
        }

        var sock = socket;
        defer sock.close();

        var first_request = true;
        while (self.running) {
            const timeout_ms = if (first_request) self.config.request_timeout_ms else self.config.keep_alive_timeout_ms;
            if (timeout_ms > 0) {
                try sock.setRecvTimeout(timeout_ms);
            }

            var buffer: [8192]u8 = undefined;
            var parser = Parser.init(self.allocator);
            defer parser.deinit();

            while (!parser.isComplete()) {
                const n = try sock.recv(&buffer);
                if (n == 0) return;
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
                return self.sendError(&sock, 500);
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

            try sock.sendAll(formatted);

            if (!keep_alive) return;
            first_request = false;
        }
    }

    fn handleHttp2Connection(self: *Self, socket: Socket) !void {
        var sock = socket;
        defer sock.close();

        if (self.config.request_timeout_ms > 0) {
            try sock.setRecvTimeout(self.config.request_timeout_ms);
        }

        var preface: [http.HTTP2_PREFACE.len]u8 = undefined;
        try readNoEofSocket(&sock, &preface);
        if (!mem.eql(u8, &preface, http.HTTP2_PREFACE)) return error.ProtocolError;

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
        defer if (authority_owned) self.allocator.free(authority_raw.?);

        var request_stream_id: ?u31 = null;
        var request_done = false;

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
                    if (frame.header.stream_id != request_stream_id.?) continue;

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

                        for (parsed.headers) |header| {
                            if (header.name.len > 0 and header.name[0] == ':') {
                                if (mem.eql(u8, header.name, ":method")) {
                                    if (method_owned) self.allocator.free(method_raw);
                                    method_raw = try self.allocator.dupe(u8, header.value);
                                    method_owned = true;
                                } else if (mem.eql(u8, header.name, ":path")) {
                                    if (path_owned) self.allocator.free(path_raw);
                                    path_raw = try self.allocator.dupe(u8, header.value);
                                    path_owned = true;
                                } else if (mem.eql(u8, header.name, ":scheme")) {
                                    if (scheme_owned) self.allocator.free(scheme_raw);
                                    scheme_raw = try self.allocator.dupe(u8, header.value);
                                    scheme_owned = true;
                                } else if (mem.eql(u8, header.name, ":authority")) {
                                    if (authority_owned) self.allocator.free(authority_raw.?);
                                    authority_raw = try self.allocator.dupe(u8, header.value);
                                    authority_owned = true;
                                }
                                continue;
                            }

                            if (common.isConnectionSpecificHeader(header.name)) continue;
                            try request_headers.append(header.name, header.value);
                        }
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

                        for (parsed.headers) |header| {
                            if (header.name.len > 0 and header.name[0] == ':') {
                                if (mem.eql(u8, header.name, ":method")) {
                                    if (method_owned) self.allocator.free(method_raw);
                                    method_raw = try self.allocator.dupe(u8, header.value);
                                    method_owned = true;
                                } else if (mem.eql(u8, header.name, ":path")) {
                                    if (path_owned) self.allocator.free(path_raw);
                                    path_raw = try self.allocator.dupe(u8, header.value);
                                    path_owned = true;
                                } else if (mem.eql(u8, header.name, ":scheme")) {
                                    if (scheme_owned) self.allocator.free(scheme_raw);
                                    scheme_raw = try self.allocator.dupe(u8, header.value);
                                    scheme_owned = true;
                                } else if (mem.eql(u8, header.name, ":authority")) {
                                    if (authority_owned) self.allocator.free(authority_raw.?);
                                    authority_raw = try self.allocator.dupe(u8, header.value);
                                    authority_owned = true;
                                }
                                continue;
                            }

                            if (common.isConnectionSpecificHeader(header.name)) continue;
                            try request_headers.append(header.name, header.value);
                        }

                        pending_headers_block.clearRetainingCapacity();
                        waiting_continuation = false;

                        if ((pending_headers_flags & 0x01) != 0) {
                            request_done = true;
                        }
                    }
                },
                .data => {
                    if (request_stream_id == null) continue;
                    if (frame.header.stream_id != request_stream_id.?) continue;

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

                    if (frame.payload.len > 0) {
                        // Replenish stream and connection receive windows as DATA is consumed.
                        const window_increment: u31 = @intCast(frame.payload.len);
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
                .rst_stream => return error.ProtocolError,
                .goaway => return,
                .window_update, .priority, .push_promise => {},
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
            var internal = Response.init(self.allocator, 500);
            defer internal.deinit();
            internal.version = .HTTP_2;
            try self.sendHttp2Response(&conn, &stream_manager, stream_id, &internal);
            return;
        };
        defer response.deinit();
        response.version = .HTTP_2;

        try self.sendHttp2Response(&conn, &stream_manager, stream_id, &response);

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

        const headers_payload = try h2stream.buildHeadersFramePayload(
            stream_manager,
            response_headers.items,
            null,
            self.allocator,
        );
        defer self.allocator.free(headers_payload.payload);

        const has_body = response.body != null and response.body.?.len > 0;
        const headers_flags: u8 = headers_payload.flags | @as(u8, if (has_body) 0 else 0x01);

        try conn.writeFrame(.{
            .length = @intCast(headers_payload.payload.len),
            .frame_type = .headers,
            .flags = headers_flags,
            .stream_id = stream_id,
        }, headers_payload.payload);

        if (has_body) {
            const body = response.body.?;
            const max_frame_size: usize = @intCast(@max(self.config.http2_settings.max_frame_size, @as(u32, 16 * 1024)));

            var offset: usize = 0;
            while (offset < body.len) {
                const chunk_len = @min(body.len - offset, max_frame_size);
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

    fn handleHttp3Transaction(self: *Self, peer_addr: net.Address, first_datagram: []const u8) !void {
        var control_stream_payload = std.ArrayList(u8).empty;
        defer control_stream_payload.deinit(self.allocator);

        var request_stream_payload = std.ArrayList(u8).empty;
        defer request_stream_payload.deinit(self.allocator);

        var request_stream_id: ?u64 = null;
        var request_done = false;
        var client_cid: ?quic.ConnectionId = null;

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
            _ = parseHttp3ControlStream(control_stream_payload.items) catch {};
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
        defer if (authority_owned) self.allocator.free(authority_raw.?);

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

                for (decoded_headers) |header| {
                    if (header.name.len > 0 and header.name[0] == ':') {
                        if (mem.eql(u8, header.name, ":method")) {
                            if (method_owned) self.allocator.free(method_raw);
                            method_raw = try self.allocator.dupe(u8, header.value);
                            method_owned = true;
                        } else if (mem.eql(u8, header.name, ":path")) {
                            if (path_owned) self.allocator.free(path_raw);
                            path_raw = try self.allocator.dupe(u8, header.value);
                            path_owned = true;
                        } else if (mem.eql(u8, header.name, ":scheme")) {
                            if (scheme_owned) self.allocator.free(scheme_raw);
                            scheme_raw = try self.allocator.dupe(u8, header.value);
                            scheme_owned = true;
                        } else if (mem.eql(u8, header.name, ":authority")) {
                            if (authority_owned) self.allocator.free(authority_raw.?);
                            authority_raw = try self.allocator.dupe(u8, header.value);
                            authority_owned = true;
                        }
                        continue;
                    }

                    if (common.isConnectionSpecificHeader(header.name)) continue;
                    try request_headers.append(header.name, header.value);
                }
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
            var internal = Response.init(self.allocator, 500);
            defer internal.deinit();
            internal.version = .HTTP_3;
            try self.sendHttp3Response(peer_addr, dst_cid, stream_id, &internal);
            return;
        };
        defer response.deinit();
        response.version = .HTTP_3;

        try self.sendHttp3Response(peer_addr, dst_cid, stream_id, &response);
    }

    fn sendHttp3Response(
        self: *Self,
        peer_addr: net.Address,
        dst_cid: quic.ConnectionId,
        request_stream_id: u64,
        response: *Response,
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

    fn executeServerRequest(self: *Self, req: *Request) !Response {
        var ctx = Context.init(self.allocator, req);
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

        var response: Response = undefined;
        if (route_result) |r| {
            response = try self.executeMiddleware(&ctx, r.handler);
        } else {
            var allow_methods: [16]types.Method = undefined;
            const allow_count = self.router.allowedMethods(req.uri.path, &allow_methods);

            if (req.method == .OPTIONS and allow_count > 0) {
                response = Response.init(self.allocator, 204);
                try self.setAllowHeader(&response.headers, allow_methods[0..allow_count]);
            } else if (allow_count > 0) {
                response = Response.init(self.allocator, 405);
                try self.setAllowHeader(&response.headers, allow_methods[0..allow_count]);
            } else if (self.global_handler) |global_handler| {
                response = try self.executeMiddleware(&ctx, global_handler);
            } else {
                response = Response.init(self.allocator, 404);
            }
        }

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
            response.status.code == 204 or
            response.status.code == 304)
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

fn readNoEofSocket(socket: *Socket, out: []u8) !void {
    var read: usize = 0;
    while (read < out.len) {
        const n = try socket.recv(out[read..]);
        if (n == 0) return error.UnexpectedEof;
        read += n;
    }
}

fn parseHttp3ControlStream(stream_data: []const u8) !void {
    if (stream_data.len == 0) return error.ProtocolError;

    var offset: usize = 0;
    const stream_type = try http.decodeVarInt(stream_data[offset..]);
    offset += stream_type.len;

    if (stream_type.value != @intFromEnum(quic.Http3StreamType.control)) {
        return error.ProtocolError;
    }

    var saw_settings = false;
    while (offset < stream_data.len) {
        const frame = try http.Http3FrameHeader.decode(stream_data[offset..]);
        offset += frame.len;

        const payload_len: usize = @intCast(frame.header.length);
        if (stream_data.len < offset + payload_len) return error.ProtocolError;

        const payload = stream_data[offset .. offset + payload_len];

        if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.settings)) {
            _ = try http.parseHttp3SettingsPayload(payload);
            saw_settings = true;
        }

        offset += payload_len;
    }

    if (!saw_settings) return error.ProtocolError;
}

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

    var packet = std.ArrayList(u8).empty;
    errdefer packet.deinit(allocator);

    var header_buf: [128]u8 = undefined;
    const header_len = try (quic.LongHeader{
        .packet_type = .initial,
        .version = .v1,
        .dcid = dcid,
        .scid = scid,
    }).encode(&header_buf);
    try packet.appendSlice(allocator, header_buf[0..header_len]);

    var packet_number_buf: [8]u8 = undefined;
    const packet_number_len = try quic.encodeVarInt(packet_number, &packet_number_buf);
    try packet.appendSlice(allocator, packet_number_buf[0..packet_number_len]);

    try packet.appendSlice(allocator, frame_storage[0..frame_len]);
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
