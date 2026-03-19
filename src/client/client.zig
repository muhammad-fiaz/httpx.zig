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
const net = std.net;

const types = @import("../core/types.zig");
const meta = @import("../core/meta.zig");
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
const common = @import("../util/common.zig");

/// HTTP client configuration.
pub const ClientConfig = struct {
    base_url: ?[]const u8 = null,
    timeouts: types.Timeouts = .{},
    retry_policy: types.RetryPolicy = .{},
    redirect_policy: types.RedirectPolicy = .{},
    default_headers: ?[]const [2][]const u8 = null,
    user_agent: []const u8 = meta.default_user_agent,
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
    config: ClientConfig,
    interceptors: std.ArrayListUnmanaged(Interceptor) = .empty,
    cookies: std.StringHashMapUnmanaged([]const u8) = .{},
    pool: ConnectionPool,

    const Self = @This();

    /// Creates a new HTTP client with default configuration.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates a new HTTP client with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ClientConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .pool = ConnectionPool.initWithConfig(allocator, .{
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

    /// Alias for request() with a shorter name for application code.
    pub fn send(self: *Self, method: types.Method, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(method, url, reqOpts);
    }

    /// Alias for GET requests in fetch-style client code.
    pub fn fetch(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.get(url, reqOpts);
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

        try self.attachCookies(&req);

        for (self.interceptors.items) |interceptor| {
            if (interceptor.request_fn) |f| {
                try f(&req, interceptor.context);
            }
        }

        var response = try self.executeRequest(&req, reqOpts.timeout_ms);
        try self.storeCookies(&response);

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
    fn executeRequest(self: *Self, req: *Request, timeout_override_ms: ?u64) !Response {
        const policy = self.config.retry_policy;
        const can_retry_method = (!policy.retry_only_idempotent) or req.method.isIdempotent();

        var attempt: u32 = 0;
        while (true) {
            var res = self.executeRequestOnce(req, timeout_override_ms) catch |err| {
                if (policy.retry_on_connection_error and can_retry_method and attempt < policy.max_retries) {
                    attempt += 1;
                    const delay_ms = policy.calculateDelay(attempt);
                    if (delay_ms > 0) std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (can_retry_method and attempt < policy.max_retries and policy.shouldRetryStatus(res.status.code)) {
                res.deinit();
                attempt += 1;
                const delay_ms = policy.calculateDelay(attempt);
                if (delay_ms > 0) std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            }

            return res;
        }
    }

    fn executeRequestOnce(self: *Self, req: *Request, timeout_override_ms: ?u64) !Response {
        const host = req.uri.host orelse return error.InvalidUri;
        const port = req.uri.effectivePort();
        const timeout_ms = timeout_override_ms orelse self.config.timeouts.read_ms;
        const write_timeout_ms = timeout_override_ms orelse self.config.timeouts.write_ms;

        const request_data = try http.formatRequest(req, self.allocator);
        defer self.allocator.free(request_data);

        if (req.uri.isTls()) {
            // TLS pooling requires keeping a live TLS session; not implemented yet.
            const addr = try address_mod.resolve(host, port);

            var socket = try Socket.createForAddress(addr);
            defer socket.close();

            if (timeout_ms > 0) {
                try socket.setRecvTimeout(timeout_ms);
            }
            if (write_timeout_ms > 0) {
                try socket.setSendTimeout(write_timeout_ms);
            }

            try socket.connect(addr);

            return self.executeTlsHttp(&socket, host, request_data);
        }

        if (self.config.keep_alive) {
            var conn = try self.pool.getConnection(host, port);
            errdefer conn.close();
            defer self.pool.releaseConnection(conn);

            if (timeout_ms > 0) {
                try conn.socket.setRecvTimeout(timeout_ms);
            }
            if (write_timeout_ms > 0) {
                try conn.socket.setSendTimeout(write_timeout_ms);
            }
            try conn.socket.setKeepAlive(true);

            try conn.socket.sendAll(request_data);
            var res = try self.readResponseFromTcp(&conn.socket);
            if (!res.headers.isKeepAlive(.HTTP_1_1)) {
                conn.close();
            }
            return res;
        }

        const addr = try address_mod.resolve(host, port);

        var socket = try Socket.createForAddress(addr);
        defer socket.close();

        if (timeout_ms > 0) {
            try socket.setRecvTimeout(timeout_ms);
        }
        if (write_timeout_ms > 0) {
            try socket.setSendTimeout(write_timeout_ms);
        }

        try socket.connect(addr);

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
        var total_read: usize = 0;
        while (!parser.isComplete()) {
            const n = try socket.recv(&buf);
            if (n == 0) break;
            total_read += n;
            if (total_read > self.config.max_response_size) return error.ResponseTooLarge;
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
        var total_read: usize = 0;
        while (!parser.isComplete()) {
            var iov = [_][]u8{buf[0..]};
            const n = r.readVec(&iov) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (n == 0) break;
            total_read += n;
            if (total_read > self.config.max_response_size) return error.ResponseTooLarge;
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

    fn attachCookies(self: *Self, req: *Request) !void {
        if (self.cookies.count() == 0) return;

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);
        const writer = list.writer(self.allocator);

        var it = self.cookies.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try writer.writeAll("; ");
            first = false;
            try writer.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        if (list.items.len > 0) {
            try req.headers.set(HeaderName.COOKIE, list.items);
        }
    }

    fn storeCookies(self: *Self, res: *const Response) !void {
        const values = try res.headers.getAll(HeaderName.SET_COOKIE, self.allocator);
        defer self.allocator.free(values);

        for (values) |set_cookie| {
            const pair = common.parseSetCookiePair(set_cookie) orelse continue;
            try self.setCookie(pair.name, pair.value);
        }
    }

    /// Adds or replaces a cookie in the in-memory client cookie jar.
    pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !void {
        if (self.cookies.fetchRemove(name)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.cookies.put(self.allocator, owned_name, owned_value);
    }

    /// Returns a cookie value from the in-memory cookie jar.
    pub fn getCookie(self: *const Self, name: []const u8) ?[]const u8 {
        return self.cookies.get(name);
    }

    /// Removes a cookie from the in-memory cookie jar.
    pub fn removeCookie(self: *Self, name: []const u8) bool {
        if (self.cookies.fetchRemove(name)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
            return true;
        }
        return false;
    }

    /// Clears all cookies from the in-memory cookie jar.
    pub fn clearCookies(self: *Self) void {
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.clearRetainingCapacity();
    }

    /// Returns true if a cookie with the given name exists in the jar.
    pub fn hasCookie(self: *const Self, name: []const u8) bool {
        return self.cookies.contains(name);
    }

    /// Returns the number of cookies currently stored in the jar.
    pub fn cookieCount(self: *const Self) usize {
        return self.cookies.count();
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

    /// Alias for httpOptions() with conventional method naming.
    pub fn options(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.httpOptions(url, reqOpts);
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
    var client = Client.init(allocator);
    defer client.deinit();

    try std.testing.expectEqualStrings(meta.default_user_agent, client.config.user_agent);
}

test "Client with config" {
    const allocator = std.testing.allocator;
    var client = Client.initWithConfig(allocator, .{
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

test "Client stores Set-Cookie headers" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    var response = Response.init(allocator, 200);
    defer response.deinit();

    try response.headers.append("Set-Cookie", "session=abc123; Path=/; HttpOnly");
    try response.headers.append("Set-Cookie", "theme=dark; Path=/");

    try client.storeCookies(&response);

    try std.testing.expectEqualStrings("abc123", client.cookies.get("session").?);
    try std.testing.expectEqualStrings("dark", client.cookies.get("theme").?);
}

test "Client attaches Cookie header from jar" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    try client.setCookie("session", "abc123");
    try client.setCookie("theme", "dark");

    var request = try Request.init(allocator, .GET, "https://example.com/");
    defer request.deinit();

    try client.attachCookies(&request);

    const cookie_header = request.headers.get("Cookie") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mem.indexOf(u8, cookie_header, "session=abc123") != null);
    try std.testing.expect(mem.indexOf(u8, cookie_header, "theme=dark") != null);
}

test "Client cookie jar public API" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    try client.setCookie("session", "abc123");
    try std.testing.expectEqualStrings("abc123", client.getCookie("session").?);

    const removed = client.removeCookie("session");
    try std.testing.expect(removed);
    try std.testing.expect(client.getCookie("session") == null);

    try client.setCookie("theme", "dark");
    try client.setCookie("lang", "en");
    client.clearCookies();
    try std.testing.expectEqual(@as(usize, 0), client.cookies.count());
}

test "Client send/fetch/options aliases" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    // Compile-time alias checks through function pointer assignment.
    const send_ptr: *const fn (*Client, types.Method, []const u8, RequestOptions) anyerror!Response = Client.send;
    const fetch_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.fetch;
    const options_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.options;
    _ = send_ptr;
    _ = fetch_ptr;
    _ = options_ptr;
}

test "Client hasCookie and cookieCount" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    try std.testing.expectEqual(@as(usize, 0), client.cookieCount());
    try std.testing.expect(!client.hasCookie("session"));

    try client.setCookie("session", "abc123");
    try std.testing.expectEqual(@as(usize, 1), client.cookieCount());
    try std.testing.expect(client.hasCookie("session"));
}
