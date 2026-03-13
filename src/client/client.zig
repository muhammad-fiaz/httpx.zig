//! HTTP Client Implementation for httpx.zig
//!
//! HTTP/1.1 client over TCP with optional TLS (HTTPS).
//!
//! Notes:
//! - HTTP/2 and HTTP/3 types exist in `src/protocol/http.zig`, but this client
//!   currently speaks HTTP/1.1.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const types = @import("../core/types.zig");
const Headers = @import("../core/headers.zig").Headers;
const HeaderName = @import("../core/headers.zig").HeaderName;
const Uri = @import("../core/uri.zig").Uri;
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;
const Status = @import("../core/status.zig").Status;
const Socket = @import("../net/socket.zig").Socket;
const SocketIoReader = @import("../net/socket.zig").SocketIoReader;
const SocketIoWriter = @import("../net/socket.zig").SocketIoWriter;
const address_mod = @import("../net/address.zig");
const http = @import("../protocol/http.zig");
const Parser = @import("../protocol/parser.zig").Parser;
const TlsConfig = @import("../tls/tls.zig").TlsConfig;
const TlsSession = @import("../tls/tls.zig").TlsSession;
const ConnectionPool = @import("pool.zig").ConnectionPool;

/// HTTP client configuration.
pub const ClientConfig = struct {
    base_url: ?[]const u8 = null,
    timeouts: types.Timeouts = .{},
    retry_policy: types.RetryPolicy = .{},
    redirect_policy: types.RedirectPolicy = .{},
    default_headers: ?[]const [2][]const u8 = null,
    user_agent: []const u8 = "httpx.zig/0.0.1",
    max_response_size: usize = 100 * 1024 * 1024,
    follow_redirects: bool = true,
    verify_ssl: bool = true,
    http2_enabled: bool = false,
    http3_enabled: bool = false,
    keep_alive: bool = true,
    pool_max_connections: u32 = 20,
    pool_max_per_host: u32 = 5,
};

/// Per-request options.
pub const RequestOptions = struct {
    headers: ?[]const [2][]const u8 = null,
    body: ?[]const u8 = null,
    json: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    follow_redirects: ?bool = null,
};

/// Request interceptor function type.
pub const RequestInterceptor = *const fn (*Request, ?*anyopaque) anyerror!void;

/// Response interceptor function type.
pub const ResponseInterceptor = *const fn (*Response, ?*anyopaque) anyerror!void;

/// Interceptor with context.
pub const Interceptor = struct {
    request_fn: ?RequestInterceptor = null,
    response_fn: ?ResponseInterceptor = null,
    context: ?*anyopaque = null,
};

/// HTTP Client.
pub const Client = struct {
    allocator: Allocator,
    io: Io,
    config: ClientConfig,
    interceptors: std.ArrayListUnmanaged(Interceptor) = .empty,
    cookies: std.StringHashMapUnmanaged([]const u8) = .{},
    pool: ConnectionPool,

    const Self = @This();

    /// Creates a new HTTP client with default configuration.
    pub fn init(allocator: Allocator, io: Io) Self {
        return initWithConfig(allocator, io, .{});
    }

    /// Creates a new HTTP client with custom configuration.
    pub fn initWithConfig(allocator: Allocator, io: Io, config: ClientConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .pool = ConnectionPool.initWithConfig(allocator, io, .{
                .max_connections = config.pool_max_connections,
                .max_per_host = config.pool_max_per_host,
            }),
        };
    }

    /// Releases all allocated resources.
    pub fn deinit(self: *Self) void {
        self.interceptors.deinit(self.allocator);
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.deinit(self.allocator);
        self.pool.deinit();
    }

    /// Adds an interceptor to the client.
    pub fn addInterceptor(self: *Self, interceptor: Interceptor) !void {
        try self.interceptors.append(self.allocator, interceptor);
    }

    /// Makes an HTTP request.
    pub fn request(self: *Self, method: types.Method, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.requestInternal(method, url, reqOpts, 0);
    }

    fn requestInternal(self: *Self, method: types.Method, url: []const u8, reqOpts: RequestOptions, depth: u32) !Response {
        const full_url = if (self.config.base_url) |base|
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, url })
        else
            try self.allocator.dupe(u8, url);
        defer self.allocator.free(full_url);

        var req = try Request.init(self.allocator, method, full_url);
        defer req.deinit();

        try req.headers.set(HeaderName.USER_AGENT, self.config.user_agent);

        if (self.config.default_headers) |hdrs| {
            for (hdrs) |h| {
                try req.headers.set(h[0], h[1]);
            }
        }

        if (reqOpts.headers) |hdrs| {
            for (hdrs) |h| {
                try req.headers.set(h[0], h[1]);
            }
        }

        if (reqOpts.body) |body| {
            try req.setBody(body);
        }

        if (reqOpts.json) |json_body| {
            try req.setJson(json_body);
        }

        for (self.interceptors.items) |interceptor| {
            if (interceptor.request_fn) |f| {
                try f(&req, interceptor.context);
            }
        }

        var response = try self.executeRequest(&req);

        for (self.interceptors.items) |interceptor| {
            if (interceptor.response_fn) |f| {
                try f(&response, interceptor.context);
            }
        }

        const should_follow = reqOpts.follow_redirects orelse self.config.follow_redirects;
        if (should_follow and response.isRedirect()) {
            if (depth >= self.config.redirect_policy.max_redirects) {
                response.deinit();
                return error.TooManyRedirects;
            }

            const location = response.headers.get(HeaderName.LOCATION) orelse {
                response.deinit();
                return error.InvalidResponse;
            };

            const next_url = try self.resolveRedirectUrl(req.uri, location);
            defer self.allocator.free(next_url);

            const next_method = self.config.redirect_policy.getRedirectMethod(response.status.code, req.method);
            response.deinit();
            return self.requestInternal(next_method, next_url, reqOpts, depth + 1);
        }

        return response;
    }

    /// Executes the actual HTTP request.
    fn executeRequest(self: *Self, req: *Request) !Response {
        const policy = self.config.retry_policy;
        const can_retry_method = (!policy.retry_only_idempotent) or req.method.isIdempotent();

        var attempt: u32 = 0;
        while (true) {
            var res = self.executeRequestOnce(req) catch |err| {
                if (policy.retry_on_connection_error and can_retry_method and attempt < policy.max_retries) {
                    attempt += 1;
                    const delay_ms = policy.calculateDelay(attempt);
                    if (delay_ms > 0) Io.sleep(self.io, .fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
                    continue;
                }
                return err;
            };

            if (can_retry_method and attempt < policy.max_retries and policy.shouldRetryStatus(res.status.code)) {
                res.deinit();
                attempt += 1;
                const delay_ms = policy.calculateDelay(attempt);
                if (delay_ms > 0) Io.sleep(self.io, .fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
                continue;
            }

            return res;
        }
    }

    fn executeRequestOnce(self: *Self, req: *Request) !Response {
        const host = req.uri.host orelse return error.InvalidUri;
        const port = req.uri.effectivePort();

        const request_data = try http.formatRequest(req, self.allocator);
        defer self.allocator.free(request_data);

        if (req.uri.isTls()) {
            // TLS pooling requires keeping a live TLS session; not implemented yet.
            const addr = try address_mod.resolve(self.io, host, port);

            var socket = try Socket.connectTo(addr);
            defer socket.close();

            if (self.config.timeouts.read_ms > 0) {
                try socket.setRecvTimeout(self.config.timeouts.read_ms);
            }
            if (self.config.timeouts.write_ms > 0) {
                try socket.setSendTimeout(self.config.timeouts.write_ms);
            }

            return self.executeTlsHttp(&socket, host, request_data);
        }

        if (self.config.keep_alive) {
            var conn = try self.pool.getConnection(host, port);
            errdefer conn.close();
            defer self.pool.releaseConnection(conn);

            if (self.config.timeouts.read_ms > 0) {
                try conn.socket.setRecvTimeout(self.config.timeouts.read_ms);
            }
            if (self.config.timeouts.write_ms > 0) {
                try conn.socket.setSendTimeout(self.config.timeouts.write_ms);
            }
            try conn.socket.setKeepAlive(true);

            try conn.socket.sendAll(request_data);
            var res = try self.readResponseFromTcp(&conn.socket);
            if (!res.headers.isKeepAlive(.HTTP_1_1)) {
                conn.close();
            }
            return res;
        }

        const addr = try address_mod.resolve(self.io, host, port);

        var socket = try Socket.connectTo(addr);
        defer socket.close();

        if (self.config.timeouts.read_ms > 0) {
            try socket.setRecvTimeout(self.config.timeouts.read_ms);
        }
        if (self.config.timeouts.write_ms > 0) {
            try socket.setSendTimeout(self.config.timeouts.write_ms);
        }

        try socket.sendAll(request_data);
        return self.readResponseFromTcp(&socket);
    }

    fn executeTlsHttp(self: *Self, socket: *Socket, host: []const u8, request_data: []const u8) !Response {
        const tls_cfg = if (self.config.verify_ssl) TlsConfig.init(self.allocator) else TlsConfig.insecure(self.allocator);

        var session = TlsSession.init(tls_cfg);
        defer session.deinit();
        session.attachSocket(socket);
        try session.handshake(host);

        const w = try session.getWriter();
        try w.writeAll(request_data);

        const r = try session.getReader();
        return self.readResponseFromIo(r);
    }

    fn readResponseFromTcp(self: *Self, socket: *Socket) !Response {
        var parser = Parser.initResponse(self.allocator);
        defer parser.deinit();

        var buf: [16 * 1024]u8 = undefined;
        while (!parser.isComplete()) {
            const n = try socket.recv(&buf);
            if (n == 0) break;
            _ = try parser.feed(buf[0..n]);
        }

        parser.finishEof();

        if (!parser.isComplete()) return error.InvalidResponse;
        return self.responseFromParser(&parser);
    }

    fn readResponseFromIo(self: *Self, r: *std.Io.Reader) !Response {
        var parser = Parser.initResponse(self.allocator);
        defer parser.deinit();

        var buf: [16 * 1024]u8 = undefined;
        while (!parser.isComplete()) {
            var iov = [_][]u8{buf[0..]};
            const n = r.readVec(&iov) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (n == 0) break;
            _ = try parser.feed(buf[0..n]);
        }

        parser.finishEof();

        if (!parser.isComplete()) return error.InvalidResponse;
        return self.responseFromParser(&parser);
    }

    fn responseFromParser(self: *Self, parser: *Parser) !Response {
        _ = self;
        const code = parser.status_code orelse return error.InvalidResponse;
        var res = Response.init(parser.allocator, code);
        errdefer res.deinit();

        // Move headers ownership from parser to response.
        res.headers.deinit();
        res.headers = parser.headers;
        parser.headers = Headers.init(parser.allocator);

        if (parser.getBody().len > 0) {
            res.body = try parser.allocator.dupe(u8, parser.getBody());
            res.body_owned = true;
        }

        return res;
    }

    fn resolveRedirectUrl(self: *Self, base: Uri, location: []const u8) ![]u8 {
        // Absolute URL.
        if (mem.indexOf(u8, location, "://") != null) {
            return self.allocator.dupe(u8, location);
        }

        const scheme = base.scheme orelse "http";
        const host = base.host orelse return error.InvalidUri;
        const port = base.effectivePort();

        if (location.len > 0 and location[0] == '/') {
            return std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{ scheme, host, port, location });
        }

        // Relative to current path.
        const base_path = base.path;
        const slash = mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
        const prefix = base_path[0 .. slash + 1];
        return std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}{s}", .{ scheme, host, port, prefix, location });
    }

    /// GET request convenience method.
    pub fn get(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.GET, url, reqOpts);
    }

    /// POST request convenience method.
    pub fn post(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.POST, url, reqOpts);
    }

    /// PUT request convenience method.
    pub fn put(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.PUT, url, reqOpts);
    }

    /// DELETE request convenience method.
    pub fn delete(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.DELETE, url, reqOpts);
    }

    /// PATCH request convenience method.
    pub fn patch(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.PATCH, url, reqOpts);
    }

    /// HEAD request convenience method.
    pub fn head(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.HEAD, url, reqOpts);
    }

    /// OPTIONS request convenience method.
    pub fn httpOptions(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.OPTIONS, url, reqOpts);
    }
};

/// Parses an HTTP response from raw data.
fn parseResponse(allocator: Allocator, data: []const u8) !Response {
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    _ = try parser.feed(data);
    if (!parser.isComplete()) return error.InvalidResponse;

    const code = parser.status_code orelse return error.InvalidResponse;
    var res = Response.init(allocator, code);
    errdefer res.deinit();

    // Move headers ownership from parser to response.
    res.headers.deinit();
    res.headers = parser.headers;
    parser.headers = Headers.init(allocator);

    if (parser.getBody().len > 0) {
        res.body = try allocator.dupe(u8, parser.getBody());
        res.body_owned = true;
    }

    return res;
}

test "Client initialization" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var client = Client.init(allocator, io);
    defer client.deinit();

    try std.testing.expectEqualStrings("httpx.zig/0.0.1", client.config.user_agent);
}

test "Client with config" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var client = Client.initWithConfig(allocator, io, .{
        .base_url = "https://api.example.com",
        .user_agent = "TestClient/1.0",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", client.config.base_url.?);
}

test "Response parsing" {
    const allocator = std.testing.allocator;
    const data = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}";

    var response = try parseResponse(allocator, data);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status.code);
    try std.testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
}
