//! HTTP Client Implementation for httpx.zig
//!
//! HTTP/1.1, HTTP/2, and HTTP/3 client runtime support.
//!
//! Notes:
//! - HTTP/2 runtime is supported with direct frame exchange.
//! - HTTP/3 runtime uses UDP + QUIC/HTTP3/QPACK primitives for local/integration
//!   endpoints. Full TLS-in-QUIC interoperability is still evolving.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../core/types.zig");
const meta = @import("../core/meta.zig");
const Headers = @import("../core/headers.zig").Headers;
const HeaderName = @import("../core/headers.zig").HeaderName;
const Uri = @import("../core/uri.zig").Uri;
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;
const Status = @import("../core/status.zig").Status;
const Socket = @import("../net/socket.zig").Socket;
const UdpSocket = @import("../net/socket.zig").UdpSocket;
const SocketIoReader = @import("../net/socket.zig").SocketIoReader;
const SocketIoWriter = @import("../net/socket.zig").SocketIoWriter;
const address_mod = @import("../net/address.zig");
const http = @import("../protocol/http.zig");
const hpack = @import("../protocol/hpack.zig");
const h2stream = @import("../protocol/stream.zig");
const qpack = @import("../protocol/qpack.zig");
const quic = @import("../protocol/quic.zig");
const Parser = @import("../protocol/parser.zig").Parser;
const TlsConfig = @import("../tls/tls.zig").TlsConfig;
const TlsSession = @import("../tls/tls.zig").TlsSession;
const ConnectionPool = @import("pool.zig").ConnectionPool;
const PoolStats = @import("pool.zig").PoolStats;
const common = @import("../util/common.zig");
const list_writer = @import("../util/list_writer.zig");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    const io = defaultIo();
    const max_i64_u64: u64 = @intCast(std.math.maxInt(i64));
    const dur = std.Io.Duration.fromMilliseconds(@intCast(@min(ms, max_i64_u64)));
    std.Io.sleep(io, dur, .real) catch {};
}

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
    http2_settings: types.Http2Settings = .{},
    http3_settings: types.Http3Settings = .{},
    keep_alive: bool = true,
    pool_max_connections: u32 = 20,
    pool_max_per_host: u32 = 5,

    /// Returns default client configuration.
    pub fn defaults() ClientConfig {
        return .{};
    }

    /// Returns default configuration with a base URL.
    pub fn forBaseUrl(base_url: []const u8) ClientConfig {
        return .{ .base_url = base_url };
    }

    /// Returns a copy with a new base URL.
    pub fn withBaseUrl(self: ClientConfig, base_url: ?[]const u8) ClientConfig {
        var out = self;
        out.base_url = base_url;
        return out;
    }

    /// Returns a copy with new timeout settings.
    pub fn withTimeouts(self: ClientConfig, timeouts: types.Timeouts) ClientConfig {
        var out = self;
        out.timeouts = timeouts;
        return out;
    }

    /// Returns a copy with a new retry policy.
    pub fn withRetryPolicy(self: ClientConfig, retry_policy: types.RetryPolicy) ClientConfig {
        var out = self;
        out.retry_policy = retry_policy;
        return out;
    }

    /// Returns a copy with a new redirect policy.
    pub fn withRedirectPolicy(self: ClientConfig, redirect_policy: types.RedirectPolicy) ClientConfig {
        var out = self;
        out.redirect_policy = redirect_policy;
        return out;
    }

    /// Returns a copy with default request headers applied to every request.
    pub fn withDefaultHeaders(self: ClientConfig, headers: ?[]const [2][]const u8) ClientConfig {
        var out = self;
        out.default_headers = headers;
        return out;
    }

    /// Returns a copy with a custom User-Agent.
    pub fn withUserAgent(self: ClientConfig, user_agent: []const u8) ClientConfig {
        var out = self;
        out.user_agent = user_agent;
        return out;
    }

    /// Returns a copy with client-level redirect-follow behavior.
    pub fn withFollowRedirects(self: ClientConfig, follow_redirects: bool) ClientConfig {
        var out = self;
        out.follow_redirects = follow_redirects;
        return out;
    }

    /// Returns a copy with protocol runtime toggles.
    pub fn withProtocols(self: ClientConfig, http2_enabled: bool, http3_enabled: bool) ClientConfig {
        var out = self;
        out.http2_enabled = http2_enabled;
        out.http3_enabled = http3_enabled;
        return out;
    }

    /// Returns a copy with explicit HTTP/2 settings.
    pub fn withHttp2Settings(self: ClientConfig, settings: types.Http2Settings) ClientConfig {
        var out = self;
        out.http2_settings = settings;
        return out;
    }

    /// Returns a copy with explicit HTTP/3 settings.
    pub fn withHttp3Settings(self: ClientConfig, settings: types.Http3Settings) ClientConfig {
        var out = self;
        out.http3_settings = settings;
        return out;
    }

    /// Returns a copy with SSL verification behavior.
    pub fn withSslVerification(self: ClientConfig, verify_ssl: bool) ClientConfig {
        var out = self;
        out.verify_ssl = verify_ssl;
        return out;
    }

    /// Returns a copy with keep-alive enablement.
    pub fn withKeepAlive(self: ClientConfig, keep_alive: bool) ClientConfig {
        var out = self;
        out.keep_alive = keep_alive;
        return out;
    }

    /// Returns a copy with maximum response-size limit.
    pub fn withMaxResponseSize(self: ClientConfig, max_response_size: usize) ClientConfig {
        var out = self;
        out.max_response_size = max_response_size;
        return out;
    }

    /// Returns a copy with connection-pool limits.
    pub fn withPoolLimits(self: ClientConfig, max_connections: u32, max_per_host: u32) ClientConfig {
        var out = self;
        out.pool_max_connections = max_connections;
        out.pool_max_per_host = max_per_host;
        return out;
    }
};

/// Basic authentication credentials used by per-request options.
pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,
};

/// Per-request options.
pub const RequestOptions = struct {
    headers: ?[]const [2][]const u8 = null,
    query_params: ?[]const [2][]const u8 = null,
    body: ?[]const u8 = null,
    json: ?[]const u8 = null,
    form_fields: ?[]const [2][]const u8 = null,
    bearer_token: ?[]const u8 = null,
    basic_auth: ?BasicAuth = null,
    timeout_ms: ?u64 = null,
    follow_redirects: ?bool = null,
    version: ?types.Version = null,

    /// Returns default request options.
    pub fn defaults() RequestOptions {
        return .{};
    }

    /// Returns a copy with request headers.
    pub fn withHeaders(self: RequestOptions, headers: []const [2][]const u8) RequestOptions {
        var out = self;
        out.headers = headers;
        return out;
    }

    /// Returns a copy with query parameters to append to the request URL.
    pub fn withQueryParams(self: RequestOptions, query_params: []const [2][]const u8) RequestOptions {
        var out = self;
        out.query_params = query_params;
        return out;
    }

    /// Returns a copy with a raw request body.
    pub fn withBody(self: RequestOptions, body: []const u8) RequestOptions {
        var out = self;
        out.body = body;
        return out;
    }

    /// Returns a copy with a JSON request body.
    pub fn withJson(self: RequestOptions, json: []const u8) RequestOptions {
        var out = self;
        out.json = json;
        return out;
    }

    /// Returns a copy with form fields encoded as application/x-www-form-urlencoded.
    pub fn withFormUrlEncoded(self: RequestOptions, form_fields: []const [2][]const u8) RequestOptions {
        var out = self;
        out.form_fields = form_fields;
        return out;
    }

    /// Returns a copy that sets `Authorization: Bearer <token>` for this request.
    /// This clears any previously set basic-auth credentials in the options copy.
    pub fn withBearerToken(self: RequestOptions, token: []const u8) RequestOptions {
        var out = self;
        out.bearer_token = token;
        out.basic_auth = null;
        return out;
    }

    /// Returns a copy that sets `Authorization: Basic ...` for this request.
    /// This clears any previously set bearer token in the options copy.
    pub fn withBasicAuth(self: RequestOptions, username: []const u8, password: []const u8) RequestOptions {
        var out = self;
        out.basic_auth = .{ .username = username, .password = password };
        out.bearer_token = null;
        return out;
    }

    /// Returns a copy with a per-request timeout.
    pub fn withTimeoutMs(self: RequestOptions, timeout_ms: u64) RequestOptions {
        var out = self;
        out.timeout_ms = timeout_ms;
        return out;
    }

    /// Returns a copy with an explicit redirect-follow policy.
    pub fn withFollowRedirects(self: RequestOptions, follow_redirects: bool) RequestOptions {
        var out = self;
        out.follow_redirects = follow_redirects;
        return out;
    }

    /// Returns a copy with an explicit HTTP version for this request.
    pub fn withVersion(self: RequestOptions, version: types.Version) RequestOptions {
        var out = self;
        out.version = version;
        return out;
    }

    /// Returns a copy that forces this request through the HTTP/2 runtime path.
    pub fn withHttp2(self: RequestOptions) RequestOptions {
        return self.withVersion(.HTTP_2);
    }

    /// Returns a copy that forces this request through the HTTP/3 runtime path.
    pub fn withHttp3(self: RequestOptions) RequestOptions {
        return self.withVersion(.HTTP_3);
    }
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
    interceptors: std.ArrayList(Interceptor) = .empty,
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

    /// Creates a new client with default settings and a base URL.
    pub fn initForBaseUrl(allocator: Allocator, base_url: []const u8) Self {
        return initWithConfig(allocator, ClientConfig.forBaseUrl(base_url));
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

    /// Removes idle or exhausted pooled connections based on pool policy.
    pub fn cleanupIdleConnections(self: *Self) void {
        self.pool.cleanup();
    }

    /// Returns a snapshot of total/active/idle pooled connection counts.
    pub fn poolStats(self: *const Self) PoolStats {
        return self.pool.stats();
    }

    /// Returns how many pooled connections are tracked for a host/port.
    pub fn hostPoolConnectionCount(self: *const Self, host: []const u8, port: u16) usize {
        return self.pool.hostConnectionCount(host, port);
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

        if (reqOpts.version) |version| {
            req.version = version;
        }

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

        if (reqOpts.query_params) |params| {
            try req.addQueryParams(params);
        }

        if (reqOpts.body) |body| {
            try req.setBody(body);
        } else if (reqOpts.json) |json_body| {
            try req.setJson(json_body);
        } else if (reqOpts.form_fields) |fields| {
            try req.setFormUrlEncoded(fields);
        }

        if (reqOpts.basic_auth) |basic| {
            try req.setBasicAuth(basic.username, basic.password);
        }
        if (reqOpts.bearer_token) |token| {
            try req.setBearerAuth(token);
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
                if (policy.retry_on_connection_error and can_retry_method and attempt < policy.max_retries and isRetryableRequestError(err)) {
                    attempt += 1;
                    const delay_ms = policy.calculateDelay(attempt);
                    if (delay_ms > 0) sleepMs(delay_ms);
                    continue;
                }
                return err;
            };

            if (can_retry_method and attempt < policy.max_retries and policy.shouldRetryStatus(res.status.code)) {
                res.deinit();
                attempt += 1;
                const delay_ms = policy.calculateDelay(attempt);
                if (delay_ms > 0) sleepMs(delay_ms);
                continue;
            }

            return res;
        }
    }

    /// Returns true for transport-layer failures that are worth retrying.
    /// TLS/protocol/parse failures are treated as deterministic and fail fast.
    fn isRetryableRequestError(err: anyerror) bool {
        const name = @errorName(err);

        if (mem.startsWith(u8, name, "Tls")) return false;

        return !(mem.eql(u8, name, "InvalidUri") or
            mem.eql(u8, name, "InvalidResponse") or
            mem.eql(u8, name, "InvalidHeader") or
            mem.eql(u8, name, "InvalidChunkSize") or
            mem.eql(u8, name, "ProtocolError") or
            mem.eql(u8, name, "Http2Error") or
            mem.eql(u8, name, "Http3Error") or
            mem.eql(u8, name, "QuicError") or
            mem.eql(u8, name, "CompressionError") or
            mem.eql(u8, name, "ResponseTooLarge") or
            mem.eql(u8, name, "RequestTooLarge") or
            mem.eql(u8, name, "TooManyRedirects"));
    }

    fn executeRequestOnce(self: *Self, req: *Request, timeout_override_ms: ?u64) !Response {
        const host = req.uri.host orelse return error.InvalidUri;
        const port = req.uri.effectivePort();
        const timeout_ms = timeout_override_ms orelse self.config.timeouts.read_ms;
        const write_timeout_ms = timeout_override_ms orelse self.config.timeouts.write_ms;

        const wants_http2 = self.config.http2_enabled or req.version == .HTTP_2;
        const wants_http3 = self.config.http3_enabled or req.version == .HTTP_3;

        if (wants_http3) {
            return self.executeRequestHttp3(req, host, port, timeout_ms, write_timeout_ms);
        }

        if (wants_http2) {
            return self.executeRequestHttp2(req, host, port, timeout_ms, write_timeout_ms);
        }

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

    fn executeRequestHttp2(
        self: *Self,
        req: *Request,
        host: []const u8,
        port: u16,
        timeout_ms: u64,
        write_timeout_ms: u64,
    ) !Response {
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

        if (req.uri.isTls()) {
            const tls_cfg = if (self.config.verify_ssl) TlsConfig.init(self.allocator) else TlsConfig.insecure(self.allocator);
            var session = TlsSession.init(tls_cfg);
            defer session.deinit();
            session.attachSocket(&socket);
            try session.handshake(host);

            var transport = TlsHttp2Transport{ .session = &session };
            return self.executeHttp2WithTransport(req, &transport);
        }

        var transport = SocketHttp2Transport{ .socket = &socket };
        return self.executeHttp2WithTransport(req, &transport);
    }

    fn executeRequestHttp3(
        self: *Self,
        req: *Request,
        host: []const u8,
        port: u16,
        timeout_ms: u64,
        write_timeout_ms: u64,
    ) !Response {
        const addr = try address_mod.resolve(host, port);

        var socket = try UdpSocket.createForAddress(addr);
        defer socket.close();

        if (timeout_ms > 0) {
            try socket.setRecvTimeout(timeout_ms);
        }
        if (write_timeout_ms > 0) {
            try socket.setSendTimeout(write_timeout_ms);
        }

        try socket.connect(addr);

        var transport = UdpHttp3Transport{ .socket = &socket };
        return self.executeHttp3WithTransport(req, &transport);
    }

    fn executeHttp3WithTransport(self: *Self, req: *Request, transport: anytype) !Response {
        var qpack_encoder = qpack.QpackContext.initWithCapacity(
            self.allocator,
            common.clampU64ToUsize(self.config.http3_settings.qpack_max_table_capacity),
        );
        defer qpack_encoder.deinit();
        qpack_encoder.max_blocked_streams = self.config.http3_settings.qpack_blocked_streams;

        var qpack_decoder = qpack.QpackContext.initWithCapacity(
            self.allocator,
            common.clampU64ToUsize(self.config.http3_settings.qpack_max_table_capacity),
        );
        defer qpack_decoder.deinit();
        qpack_decoder.max_blocked_streams = self.config.http3_settings.qpack_blocked_streams;

        var path_buf: ?[]u8 = null;
        defer if (path_buf) |buf| self.allocator.free(buf);
        const path = if (req.uri.query) |q| blk: {
            path_buf = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ req.uri.path, q });
            break :blk path_buf.?;
        } else req.uri.path;

        var authority_buf: ?[]u8 = null;
        defer if (authority_buf) |buf| self.allocator.free(buf);
        const authority = try buildAuthority(self.allocator, req, &authority_buf);

        var header_entries = std.ArrayList(qpack.HeaderEntry).empty;
        defer header_entries.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| self.allocator.free(name);
            owned_header_names.deinit(self.allocator);
        }

        const method_value = if (req.method == .CUSTOM)
            (req.custom_method orelse "CUSTOM")
        else
            req.method.toString();

        try header_entries.append(self.allocator, .{ .name = ":method", .value = method_value });
        try header_entries.append(self.allocator, .{ .name = ":path", .value = path });
        try header_entries.append(self.allocator, .{ .name = ":scheme", .value = if (req.uri.isTls()) "https" else "http" });
        try header_entries.append(self.allocator, .{ .name = ":authority", .value = authority });

        for (req.headers.entries.items) |entry| {
            if (common.isConnectionSpecificHeader(entry.name) or std.ascii.eqlIgnoreCase(entry.name, HeaderName.HOST)) {
                continue;
            }
            if (entry.name.len > 0 and entry.name[0] == ':') continue;

            const lowered_name = try common.dupLowerAscii(self.allocator, entry.name);
            try owned_header_names.append(self.allocator, lowered_name);
            try header_entries.append(self.allocator, .{ .name = lowered_name, .value = entry.value });
        }

        const headers_block = try qpack.encodeHeaders(&qpack_encoder, header_entries.items, self.allocator);
        defer self.allocator.free(headers_block);

        var request_stream_payload = std.ArrayList(u8).empty;
        defer request_stream_payload.deinit(self.allocator);
        try http.appendHttp3Frame(&request_stream_payload, self.allocator, .headers, headers_block);

        if (req.body) |body| {
            if (body.len > 0) {
                try http.appendHttp3Frame(&request_stream_payload, self.allocator, .data, body);
            }
        }

        var settings_payload = std.ArrayList(u8).empty;
        defer settings_payload.deinit(self.allocator);
        try http.encodeHttp3SettingsPayload(self.config.http3_settings, self.allocator, &settings_payload);

        var control_stream_payload = std.ArrayList(u8).empty;
        defer control_stream_payload.deinit(self.allocator);
        try http.appendVarInt(&control_stream_payload, self.allocator, @intFromEnum(quic.Http3StreamType.control));
        try http.appendHttp3Frame(&control_stream_payload, self.allocator, .settings, settings_payload.items);

        var session = Http3QuicSession.initClient();

        // Client control stream (id=2) and request stream (id=0).
        try self.sendHttp3StreamData(transport, &session, 2, false, control_stream_payload.items);
        try self.sendHttp3StreamData(transport, &session, 0, true, request_stream_payload.items);

        var response_stream_payload = std.ArrayList(u8).empty;
        defer response_stream_payload.deinit(self.allocator);

        var peer_control_payload = std.ArrayList(u8).empty;
        defer peer_control_payload.deinit(self.allocator);

        var read_buf: [64 * 1024]u8 = undefined;
        var got_response_fin = false;

        var packet_counter: usize = 0;
        while (!got_response_fin) {
            packet_counter += 1;
            if (packet_counter > 10_000) return error.ProtocolError;

            const n = try transport.recvDatagram(&read_buf);
            if (n == 0) continue;

            const incoming = try decodeHttp3StreamDatagram(read_buf[0..n], &session);

            if (incoming.stream_id == 0) {
                if (response_stream_payload.items.len + incoming.data.len > self.config.max_response_size) {
                    return error.ResponseTooLarge;
                }
                try response_stream_payload.appendSlice(self.allocator, incoming.data);
                if (incoming.fin) {
                    got_response_fin = true;
                }
            } else if (incoming.stream_id == 3) {
                if (peer_control_payload.items.len + incoming.data.len > self.config.max_response_size) {
                    return error.ResponseTooLarge;
                }
                try peer_control_payload.appendSlice(self.allocator, incoming.data);
            }
        }

        if (peer_control_payload.items.len > 0) {
            try parseHttp3ControlStream(peer_control_payload.items);
        }

        var response_headers = Headers.init(self.allocator);
        defer response_headers.deinit();

        var response_body = std.ArrayList(u8).empty;
        defer response_body.deinit(self.allocator);

        var status_code: ?u16 = null;
        try self.parseHttp3ResponseFrames(
            &qpack_decoder,
            response_stream_payload.items,
            &status_code,
            &response_headers,
            &response_body,
        );

        const final_status = status_code orelse return error.InvalidResponse;

        var response = Response.init(self.allocator, final_status);
        errdefer response.deinit();
        response.version = .HTTP_3;

        response.headers.deinit();
        response.headers = response_headers;
        response_headers = Headers.init(self.allocator);

        if (response_body.items.len > 0) {
            response.body = try response_body.toOwnedSlice(self.allocator);
            response.body_owned = true;
        }

        return response;
    }

    fn sendHttp3StreamData(
        self: *Self,
        transport: anytype,
        session: *Http3QuicSession,
        stream_id: u64,
        fin: bool,
        payload: []const u8,
    ) !void {
        const max_chunk_size: usize = 1200;

        var offset: usize = 0;
        var sent_any = false;

        while (offset < payload.len or !sent_any) {
            const chunk_len = if (offset < payload.len)
                @min(max_chunk_size, payload.len - offset)
            else
                0;

            const chunk = payload[offset .. offset + chunk_len];
            const chunk_fin = fin and (offset + chunk_len == payload.len);

            const frame_storage = try self.allocator.alloc(u8, chunk_len + 64);
            defer self.allocator.free(frame_storage);

            const stream_frame = quic.StreamFrame{
                .stream_id = stream_id,
                .offset = @intCast(offset),
                .length = @intCast(chunk_len),
                .fin = chunk_fin,
                .data = chunk,
            };

            const frame_len = try stream_frame.encode(frame_storage);

            var packet = std.ArrayList(u8).empty;
            defer packet.deinit(self.allocator);

            try appendHttp3PacketHeader(&packet, self.allocator, session);
            try packet.appendSlice(self.allocator, frame_storage[0..frame_len]);

            try transport.sendDatagram(packet.items);

            sent_any = true;
            offset += chunk_len;

            if (payload.len == 0) break;
        }
    }

    fn parseHttp3ResponseFrames(
        self: *Self,
        qpack_decoder: *qpack.QpackContext,
        payload: []const u8,
        status_code: *?u16,
        response_headers: *Headers,
        response_body: *std.ArrayList(u8),
    ) !void {
        var offset: usize = 0;

        while (offset < payload.len) {
            const header_decoded = http.Http3FrameHeader.decode(payload[offset..]) catch return error.InvalidResponse;
            offset += header_decoded.len;

            const frame_len: usize = @intCast(header_decoded.header.length);
            if (payload.len < offset + frame_len) return error.InvalidResponse;

            const frame_payload = payload[offset .. offset + frame_len];
            offset += frame_len;

            switch (header_decoded.header.frame_type) {
                @intFromEnum(http.Http3FrameType.headers) => {
                    const decoded_headers = try qpack.decodeHeaders(qpack_decoder, frame_payload, self.allocator);
                    defer {
                        for (decoded_headers) |h| {
                            self.allocator.free(h.name);
                            self.allocator.free(h.value);
                        }
                        self.allocator.free(decoded_headers);
                    }

                    for (decoded_headers) |h| {
                        if (h.name.len > 0 and h.name[0] == ':') {
                            if (mem.eql(u8, h.name, ":status")) {
                                status_code.* = std.fmt.parseInt(u16, h.value, 10) catch return error.InvalidResponse;
                            }
                            continue;
                        }

                        if (common.isConnectionSpecificHeader(h.name)) continue;
                        try response_headers.append(h.name, h.value);
                    }
                },
                @intFromEnum(http.Http3FrameType.data) => {
                    if (response_body.items.len + frame_payload.len > self.config.max_response_size) {
                        return error.ResponseTooLarge;
                    }
                    try response_body.appendSlice(self.allocator, frame_payload);
                },
                @intFromEnum(http.Http3FrameType.settings) => {
                    _ = try http.parseHttp3SettingsPayload(frame_payload);
                },
                @intFromEnum(http.Http3FrameType.goaway) => {},
                else => {
                    // Unknown/unsupported frame types are ignored for forward compatibility.
                },
            }
        }
    }

    fn executeHttp2WithTransport(self: *Self, req: *Request, transport: anytype) !Response {
        var stream_manager = h2stream.StreamManager.init(self.allocator, true);
        defer stream_manager.deinit();

        try transport.writeAll(http.HTTP2_PREFACE);

        var settings_payload = std.ArrayList(u8).empty;
        defer settings_payload.deinit(self.allocator);

        const local_settings = toConnectionSettings(self.config.http2_settings);
        try http.encodeSettingsPayload(local_settings, self.allocator, &settings_payload);
        try writeHttp2Frame(transport, .settings, 0, 0, settings_payload.items);

        const request_stream = try stream_manager.createStream();
        try request_stream.open();

        var path_buf: ?[]u8 = null;
        defer if (path_buf) |buf| self.allocator.free(buf);
        const path = if (req.uri.query) |q| blk: {
            path_buf = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ req.uri.path, q });
            break :blk path_buf.?;
        } else req.uri.path;

        var authority_buf: ?[]u8 = null;
        defer if (authority_buf) |buf| self.allocator.free(buf);
        const authority = try buildAuthority(self.allocator, req, &authority_buf);

        var header_entries = std.ArrayList(hpack.HeaderEntry).empty;
        defer header_entries.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| self.allocator.free(name);
            owned_header_names.deinit(self.allocator);
        }

        const method_value = if (req.method == .CUSTOM)
            (req.custom_method orelse "CUSTOM")
        else
            req.method.toString();

        try header_entries.append(self.allocator, .{ .name = ":method", .value = method_value });
        try header_entries.append(self.allocator, .{ .name = ":path", .value = path });
        try header_entries.append(self.allocator, .{ .name = ":scheme", .value = if (req.uri.isTls()) "https" else "http" });
        try header_entries.append(self.allocator, .{ .name = ":authority", .value = authority });

        for (req.headers.entries.items) |entry| {
            if (common.isConnectionSpecificHeader(entry.name) or std.ascii.eqlIgnoreCase(entry.name, HeaderName.HOST)) {
                continue;
            }
            if (entry.name.len > 0 and entry.name[0] == ':') continue;

            const lowered_name = try common.dupLowerAscii(self.allocator, entry.name);
            try owned_header_names.append(self.allocator, lowered_name);
            try header_entries.append(self.allocator, .{ .name = lowered_name, .value = entry.value });
        }

        const headers_payload = try h2stream.buildHeadersFramePayload(
            &stream_manager,
            header_entries.items,
            null,
            self.allocator,
        );
        defer self.allocator.free(headers_payload.payload);

        const has_body = req.body != null and req.body.?.len > 0;
        const headers_flags: u8 = headers_payload.flags | @as(u8, if (has_body) 0 else 0x01);
        try writeHttp2Frame(transport, .headers, headers_flags, request_stream.id, headers_payload.payload);

        if (has_body) {
            const body = req.body.?;
            var offset: usize = 0;
            while (offset < body.len) {
                const chunk_len = @min(body.len - offset, @as(usize, local_settings.max_frame_size));
                const is_last = offset + chunk_len == body.len;
                const chunk_flags: u8 = if (is_last) 0x01 else 0;
                try writeHttp2Frame(
                    transport,
                    .data,
                    chunk_flags,
                    request_stream.id,
                    body[offset .. offset + chunk_len],
                );
                offset += chunk_len;
            }
            request_stream.sendEndStream();
        } else {
            request_stream.sendEndStream();
        }

        var response_headers = Headers.init(self.allocator);
        defer response_headers.deinit();

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);

        var pending_headers_block = std.ArrayList(u8).empty;
        defer pending_headers_block.deinit(self.allocator);

        var pending_headers_flags: u8 = 0;
        var waiting_continuation = false;

        var status_code: ?u16 = null;
        var response_done = false;

        var peer_settings = http.Http2Connection.Http2ConnectionSettings{};

        var frame_counter: usize = 0;
        while (!response_done) {
            frame_counter += 1;
            if (frame_counter > 10_000) return error.ProtocolError;

            const frame = self.readHttp2Frame(transport) catch |err| switch (err) {
                error.UnexpectedEof => return error.InvalidResponse,
                else => return err,
            };
            defer self.allocator.free(frame.payload);

            switch (frame.header.frame_type) {
                .settings => {
                    if (frame.header.stream_id != 0) return error.ProtocolError;
                    const is_ack = (frame.header.flags & 0x01) != 0;
                    if (!is_ack) {
                        try http.applySettingsPayload(&peer_settings, frame.payload);
                        try writeHttp2Frame(transport, .settings, 0x01, 0, &.{});
                    }
                },
                .ping => {
                    if (frame.header.stream_id != 0) return error.ProtocolError;
                    const is_ack = (frame.header.flags & 0x01) != 0;
                    if (!is_ack) {
                        if (frame.payload.len != 8) return error.ProtocolError;
                        try writeHttp2Frame(transport, .ping, 0x01, 0, frame.payload);
                    }
                },
                .goaway => {
                    if (status_code == null) return error.ProtocolError;
                },
                .window_update, .priority, .push_promise => {},
                .rst_stream => {
                    if (frame.header.stream_id == request_stream.id) return error.StreamError;
                },
                .headers => {
                    if (frame.header.stream_id != request_stream.id) continue;
                    if (waiting_continuation) return error.ProtocolError;

                    if ((frame.header.flags & 0x04) != 0) {
                        const expect_initial_headers = status_code == null;
                        try applyResponseHeaderBlock(
                            self,
                            &stream_manager,
                            frame.payload,
                            frame.header.flags,
                            expect_initial_headers,
                            &status_code,
                            &response_headers,
                        );
                        if ((frame.header.flags & 0x01) != 0) {
                            response_done = true;
                            request_stream.receiveEndStream();
                        }
                    } else {
                        pending_headers_flags = frame.header.flags;
                        try pending_headers_block.appendSlice(self.allocator, frame.payload);
                        waiting_continuation = true;
                    }
                },
                .continuation => {
                    if (frame.header.stream_id != request_stream.id) continue;
                    if (!waiting_continuation) return error.ProtocolError;

                    try pending_headers_block.appendSlice(self.allocator, frame.payload);
                    if ((frame.header.flags & 0x04) != 0) {
                        const expect_initial_headers = status_code == null;
                        try applyResponseHeaderBlock(
                            self,
                            &stream_manager,
                            pending_headers_block.items,
                            pending_headers_flags,
                            expect_initial_headers,
                            &status_code,
                            &response_headers,
                        );
                        pending_headers_block.clearRetainingCapacity();
                        waiting_continuation = false;

                        if ((pending_headers_flags & 0x01) != 0) {
                            response_done = true;
                            request_stream.receiveEndStream();
                        }
                    }
                },
                .data => {
                    if (frame.header.stream_id != request_stream.id) continue;

                    var data_slice = frame.payload;
                    if ((frame.header.flags & 0x08) != 0) {
                        if (frame.payload.len == 0) return error.ProtocolError;
                        const pad_len = frame.payload[0];
                        if (frame.payload.len < @as(usize, pad_len) + 1) return error.ProtocolError;
                        data_slice = frame.payload[1 .. frame.payload.len - pad_len];
                    }

                    if (body.items.len + data_slice.len > self.config.max_response_size) return error.ResponseTooLarge;
                    try body.appendSlice(self.allocator, data_slice);

                    if (frame.payload.len > 0) {
                        // Keep stream and connection windows replenished while consuming DATA.
                        const window_increment: u31 = @intCast(frame.payload.len);
                        const window_update = h2stream.buildWindowUpdatePayload(window_increment);
                        try writeHttp2Frame(transport, .window_update, 0, request_stream.id, &window_update);
                        try writeHttp2Frame(transport, .window_update, 0, 0, &window_update);
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        response_done = true;
                        request_stream.receiveEndStream();
                    }
                },
            }
        }

        if (waiting_continuation) return error.InvalidResponse;

        const final_status = status_code orelse return error.InvalidResponse;

        var response = Response.init(self.allocator, final_status);
        errdefer response.deinit();
        response.version = .HTTP_2;

        response.headers.deinit();
        response.headers = response_headers;
        response_headers = Headers.init(self.allocator);

        if (body.items.len > 0) {
            response.body = try body.toOwnedSlice(self.allocator);
            response.body_owned = true;
        }

        return response;
    }

    fn readHttp2Frame(self: *Self, transport: anytype) !struct { header: http.Http2FrameHeader, payload: []u8 } {
        var header_bytes: [9]u8 = undefined;
        try transport.readNoEof(&header_bytes);
        const header = http.Http2FrameHeader.parse(header_bytes);

        const payload_len: usize = @intCast(header.length);
        if (payload_len > self.config.max_response_size) return error.FrameTooLarge;

        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            try transport.readNoEof(payload);
        }

        return .{ .header = header, .payload = payload };
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

        var list = std.ArrayList(u8).empty;
        defer list.deinit(self.allocator);
        const writer = list_writer.init(self.allocator, &list);

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

    /// Alias for delete() with short method naming.
    pub fn del(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.delete(url, reqOpts);
    }

    /// PATCH request convenience method.
    pub fn patch(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.PATCH, url, reqOpts);
    }

    /// HEAD request convenience method.
    pub fn head(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.HEAD, url, reqOpts);
    }

    /// TRACE request convenience method.
    pub fn trace(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.TRACE, url, reqOpts);
    }

    /// CONNECT request convenience method.
    pub fn connect(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.CONNECT, url, reqOpts);
    }

    /// OPTIONS request convenience method.
    pub fn httpOptions(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.OPTIONS, url, reqOpts);
    }

    /// Alias for httpOptions() with conventional method naming.
    pub fn options(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.httpOptions(url, reqOpts);
    }

    /// Alias for options() with short method naming.
    pub fn opts(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.options(url, reqOpts);
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

const SocketHttp2Transport = struct {
    socket: *Socket,

    fn writeAll(self: *SocketHttp2Transport, data: []const u8) !void {
        try self.socket.sendAll(data);
    }

    fn readNoEof(self: *SocketHttp2Transport, out: []u8) !void {
        var read: usize = 0;
        while (read < out.len) {
            const n = try self.socket.recv(out[read..]);
            if (n == 0) return error.UnexpectedEof;
            read += n;
        }
    }
};

const TlsHttp2Transport = struct {
    session: *TlsSession,

    fn writeAll(self: *TlsHttp2Transport, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.session.write(data[written..]);
            if (n == 0) return error.UnexpectedEof;
            written += n;
        }
    }

    fn readNoEof(self: *TlsHttp2Transport, out: []u8) !void {
        var read: usize = 0;
        while (read < out.len) {
            const n = try self.session.read(out[read..]);
            if (n == 0) return error.UnexpectedEof;
            read += n;
        }
    }
};

const UdpHttp3Transport = struct {
    socket: *UdpSocket,

    fn sendDatagram(self: *UdpHttp3Transport, data: []const u8) !void {
        const sent = try self.socket.send(data);
        if (sent != data.len) return error.ShortWrite;
    }

    fn recvDatagram(self: *UdpHttp3Transport, out: []u8) !usize {
        return self.socket.recv(out);
    }
};

const Http3QuicSession = struct {
    local_cid: quic.ConnectionId,
    peer_cid: quic.ConnectionId,
    next_packet_number: u64 = 0,
    sent_initial: bool = false,

    fn initClient() Http3QuicSession {
        return .{
            .local_cid = quic.ConnectionId.random(),
            .peer_cid = quic.ConnectionId.random(),
        };
    }
};

const DecodedHttp3StreamDatagram = struct {
    stream_id: u64,
    fin: bool,
    data: []const u8,
};

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
        const frame = http.Http3FrameHeader.decode(stream_data[offset..]) catch return error.ProtocolError;
        offset += frame.len;

        const payload_len: usize = @intCast(frame.header.length);
        if (stream_data.len < offset + payload_len) return error.ProtocolError;

        const payload = stream_data[offset .. offset + payload_len];
        offset += payload_len;

        if (frame.header.frame_type == @intFromEnum(http.Http3FrameType.settings)) {
            _ = try http.parseHttp3SettingsPayload(payload);
            saw_settings = true;
        }
    }

    if (!saw_settings) return error.ProtocolError;
}

fn appendHttp3PacketHeader(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    session: *Http3QuicSession,
) !void {
    var hdr_buf: [128]u8 = undefined;

    const hdr_len = if (!session.sent_initial) blk: {
        const long_header = quic.LongHeader{
            .packet_type = .initial,
            .version = .v1,
            .dcid = session.peer_cid,
            .scid = session.local_cid,
        };
        const n = try long_header.encode(&hdr_buf);
        session.sent_initial = true;
        break :blk n;
    } else blk: {
        const short_header = quic.ShortHeader{ .dcid = session.peer_cid };
        break :blk try short_header.encode(&hdr_buf);
    };

    try out.appendSlice(allocator, hdr_buf[0..hdr_len]);

    var pn_buf: [8]u8 = undefined;
    const pn_len = try quic.encodeVarInt(session.next_packet_number, &pn_buf);
    session.next_packet_number += 1;
    try out.appendSlice(allocator, pn_buf[0..pn_len]);
}

fn decodeHttp3StreamDatagram(datagram: []const u8, session: *Http3QuicSession) !DecodedHttp3StreamDatagram {
    if (datagram.len == 0) return error.InvalidResponse;

    var offset: usize = 0;

    if ((datagram[0] & 0x80) != 0) {
        const long_decoded = try quic.LongHeader.decode(datagram);
        offset = long_decoded.len;
        if (long_decoded.header.scid.len > 0) {
            session.peer_cid = long_decoded.header.scid;
        }
    } else {
        const short_decoded = try quic.ShortHeader.decode(datagram, session.local_cid.len);
        offset = short_decoded.len;
    }

    const packet_number = try quic.decodeVarInt(datagram[offset..]);
    _ = packet_number.value;
    offset += packet_number.len;

    if (offset >= datagram.len) return error.InvalidResponse;
    if (!quic.FrameType.isStream(@as(u64, datagram[offset]))) return error.ProtocolError;

    const stream_decoded = try quic.StreamFrame.decode(datagram[offset..]);
    if (stream_decoded.len != datagram[offset..].len) return error.ProtocolError;

    return .{
        .stream_id = stream_decoded.frame.stream_id,
        .fin = stream_decoded.frame.fin,
        .data = stream_decoded.frame.data,
    };
}

fn toConnectionSettings(settings: types.Http2Settings) http.Http2Connection.Http2ConnectionSettings {
    return .{
        .header_table_size = settings.header_table_size,
        .enable_push = settings.enable_push,
        .max_concurrent_streams = settings.max_concurrent_streams,
        .initial_window_size = settings.initial_window_size,
        .max_frame_size = settings.max_frame_size,
        .max_header_list_size = settings.max_header_list_size,
    };
}

fn buildAuthority(allocator: Allocator, req: *const Request, authority_buf: *?[]u8) ![]const u8 {
    const host = req.uri.host orelse return error.InvalidUri;
    const explicit_port = req.uri.port orelse return host;
    const default_port: u16 = if (req.uri.isTls()) 443 else 80;

    if (explicit_port == default_port) return host;

    authority_buf.* = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, explicit_port });
    return authority_buf.*.?;
}

fn writeHttp2Frame(
    transport: anytype,
    frame_type: http.Http2FrameType,
    flags: u8,
    stream_id: u31,
    payload: []const u8,
) !void {
    const header = http.Http2FrameHeader{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = stream_id,
    };
    const raw_header = header.serialize();
    try transport.writeAll(&raw_header);
    if (payload.len > 0) {
        try transport.writeAll(payload);
    }
}

fn applyResponseHeaderBlock(
    self: *Client,
    stream_manager: *h2stream.StreamManager,
    header_block: []const u8,
    flags: u8,
    expect_initial_headers: bool,
    status_code: *?u16,
    response_headers: *Headers,
) !void {
    const parsed = try h2stream.parseHeadersFramePayload(stream_manager, header_block, flags, self.allocator);
    defer {
        for (parsed.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(parsed.headers);
    }

    var saw_status = false;

    for (parsed.headers) |header| {
        if (header.name.len > 0 and header.name[0] == ':') {
            if (mem.eql(u8, header.name, ":status")) {
                if (!expect_initial_headers or status_code.* != null or saw_status) {
                    return error.ProtocolError;
                }
                status_code.* = std.fmt.parseInt(u16, header.value, 10) catch return error.InvalidResponse;
                saw_status = true;
            } else {
                return error.ProtocolError;
            }
            continue;
        }

        if (common.isConnectionSpecificHeader(header.name)) continue;
        try response_headers.append(header.name, header.value);
    }

    if (expect_initial_headers and !saw_status and status_code.* == null) {
        return error.InvalidResponse;
    }
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

test "Client initForBaseUrl helper" {
    const allocator = std.testing.allocator;
    var client = Client.initForBaseUrl(allocator, "https://api.example.com");
    defer client.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", client.config.base_url.?);
}

test "ClientConfig builder helpers" {
    const default_headers = [_][2][]const u8{
        .{ "Accept", "application/json" },
    };

    const cfg = ClientConfig.defaults()
        .withBaseUrl("https://api.example.com")
        .withTimeouts(types.Timeouts.fast())
        .withRetryPolicy(types.RetryPolicy.noRetry())
        .withRedirectPolicy(types.RedirectPolicy.strict())
        .withDefaultHeaders(&default_headers)
        .withUserAgent("MyClient/1.0")
        .withFollowRedirects(false)
        .withProtocols(true, false)
        .withHttp2Settings(.{ .max_concurrent_streams = 42 })
        .withHttp3Settings(.{ .enable_datagrams = true })
        .withSslVerification(false)
        .withKeepAlive(false)
        .withMaxResponseSize(1024)
        .withPoolLimits(64, 16);

    try std.testing.expectEqualStrings("https://api.example.com", cfg.base_url.?);
    try std.testing.expectEqual(@as(u64, 5_000), cfg.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.retry_policy.max_retries);
    try std.testing.expect(cfg.redirect_policy.preserve_method);
    try std.testing.expect(cfg.default_headers != null);
    try std.testing.expectEqual(@as(usize, 1), cfg.default_headers.?.len);
    try std.testing.expectEqualStrings("MyClient/1.0", cfg.user_agent);
    try std.testing.expect(!cfg.follow_redirects);
    try std.testing.expect(cfg.http2_enabled);
    try std.testing.expect(!cfg.http3_enabled);
    try std.testing.expectEqual(@as(u32, 42), cfg.http2_settings.max_concurrent_streams);
    try std.testing.expect(cfg.http3_settings.enable_datagrams);
    try std.testing.expect(!cfg.verify_ssl);
    try std.testing.expect(!cfg.keep_alive);
    try std.testing.expectEqual(@as(usize, 1024), cfg.max_response_size);
    try std.testing.expectEqual(@as(u32, 64), cfg.pool_max_connections);
    try std.testing.expectEqual(@as(u32, 16), cfg.pool_max_per_host);
}

test "RequestOptions builder helpers" {
    const headers = [_][2][]const u8{
        .{ "Authorization", "Bearer test" },
        .{ "Accept", "application/json" },
    };
    const query_params = [_][2][]const u8{
        .{ "page", "1" },
        .{ "sort", "desc" },
    };
    const form_fields = [_][2][]const u8{
        .{ "email", "user@example.com" },
    };

    const opts = RequestOptions.defaults()
        .withHeaders(&headers)
        .withQueryParams(&query_params)
        .withJson("{\"ok\":true}")
        .withFormUrlEncoded(&form_fields)
        .withBearerToken("token-123")
        .withTimeoutMs(2_500)
        .withFollowRedirects(false)
        .withVersion(.HTTP_2);

    try std.testing.expect(opts.headers != null);
    try std.testing.expectEqual(@as(usize, 2), opts.headers.?.len);
    try std.testing.expect(opts.query_params != null);
    try std.testing.expectEqual(@as(usize, 2), opts.query_params.?.len);
    try std.testing.expectEqualStrings("{\"ok\":true}", opts.json.?);
    try std.testing.expect(opts.form_fields != null);
    try std.testing.expectEqual(@as(usize, 1), opts.form_fields.?.len);
    try std.testing.expectEqualStrings("token-123", opts.bearer_token.?);
    try std.testing.expect(opts.basic_auth == null);
    try std.testing.expectEqual(@as(u64, 2_500), opts.timeout_ms.?);
    try std.testing.expect(!opts.follow_redirects.?);
    try std.testing.expectEqual(types.Version.HTTP_2, opts.version.?);

    const basic = RequestOptions.defaults().withBasicAuth("demo", "pass");
    try std.testing.expect(basic.basic_auth != null);
    try std.testing.expectEqualStrings("demo", basic.basic_auth.?.username);
    try std.testing.expectEqualStrings("pass", basic.basic_auth.?.password);
    try std.testing.expect(basic.bearer_token == null);

    const h3 = RequestOptions.defaults().withHttp3();
    try std.testing.expectEqual(types.Version.HTTP_3, h3.version.?);
}

test "Response parsing" {
    const allocator = std.testing.allocator;
    const data =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 15\r\n" ++
        "\r\n" ++
        "{\"status\":\"ok\"}";

    var response = try parseResponse(allocator, data);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status.code);
    try std.testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", response.text() orelse "");
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
    const del_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.del;
    const trace_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.trace;
    const connect_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.connect;
    const options_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.options;
    const opts_ptr: *const fn (*Client, []const u8, RequestOptions) anyerror!Response = Client.opts;
    _ = send_ptr;
    _ = fetch_ptr;
    _ = del_ptr;
    _ = trace_ptr;
    _ = connect_ptr;
    _ = options_ptr;
    _ = opts_ptr;
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

test "Client pool helpers" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    client.cleanupIdleConnections();
    const stats = client.poolStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);
    try std.testing.expectEqual(@as(usize, 0), client.hostPoolConnectionCount("example.com", 443));
}

test "Client retry classifier avoids TLS/protocol retries" {
    try std.testing.expect(!Client.isRetryableRequestError(error.TlsConnectionTruncated));
    try std.testing.expect(!Client.isRetryableRequestError(error.InvalidResponse));
    try std.testing.expect(!Client.isRetryableRequestError(error.ProtocolError));
    try std.testing.expect(Client.isRetryableRequestError(error.ConnectionReset));
}

test "Client HTTP/2 runtime parses headers and data" {
    const allocator = std.testing.allocator;

    var client = Client.initWithConfig(allocator, .{ .http2_enabled = true });
    defer client.deinit();

    var req = try Request.init(allocator, .GET, "http://example.com/resource");
    defer req.deinit();

    var server_stream_manager = h2stream.StreamManager.init(allocator, false);
    defer server_stream_manager.deinit();

    const server_headers = [_]hpack.HeaderEntry{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };

    const server_trailers = [_]hpack.HeaderEntry{
        .{ .name = "etag", .value = "W/\"demo\"" },
    };

    const headers_payload = try h2stream.buildHeadersFramePayload(
        &server_stream_manager,
        &server_headers,
        null,
        allocator,
    );
    defer allocator.free(headers_payload.payload);

    const trailers_payload = try h2stream.buildHeadersFramePayload(
        &server_stream_manager,
        &server_trailers,
        null,
        allocator,
    );
    defer allocator.free(trailers_payload.payload);

    var read_bytes = std.ArrayList(u8).empty;
    defer read_bytes.deinit(allocator);

    var server_settings = std.ArrayList(u8).empty;
    defer server_settings.deinit(allocator);
    try http.encodeSettingsPayload(.{}, allocator, &server_settings);

    try appendFrameBytes(allocator, &read_bytes, .settings, 0, 0, server_settings.items);
    try appendFrameBytes(allocator, &read_bytes, .headers, headers_payload.flags, 1, headers_payload.payload);
    try appendFrameBytes(allocator, &read_bytes, .data, 0x00, 1, "hello");
    try appendFrameBytes(allocator, &read_bytes, .headers, trailers_payload.flags | 0x01, 1, trailers_payload.payload);

    var transport = FakeHttp2Transport.init(allocator, read_bytes.items);
    defer transport.deinit();

    var response = try client.executeHttp2WithTransport(&req, &transport);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status.code);
    try std.testing.expectEqual(types.Version.HTTP_2, response.version);
    try std.testing.expectEqualStrings("text/plain", response.headers.get("content-type").?);
    try std.testing.expectEqualStrings("W/\"demo\"", response.headers.get("etag").?);
    try std.testing.expectEqualStrings("hello", response.text().?);

    try std.testing.expect(mem.startsWith(u8, transport.writes.items, http.HTTP2_PREFACE));
    try std.testing.expect(countWrittenHttp2Frames(transport.writes.items, .window_update) >= 2);
}

test "Client HTTP/3 runtime parses headers and data" {
    const allocator = std.testing.allocator;

    var client = Client.initWithConfig(allocator, .{ .http3_enabled = true, .http2_enabled = false });
    defer client.deinit();

    var req = try Request.init(allocator, .GET, "http://example.com/resource");
    defer req.deinit();

    var server_qpack = qpack.QpackContext.init(allocator);
    defer server_qpack.deinit();

    const server_headers = [_]qpack.HeaderEntry{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };

    const encoded_server_headers = try qpack.encodeHeaders(&server_qpack, &server_headers, allocator);
    defer allocator.free(encoded_server_headers);

    var response_stream_payload = std.ArrayList(u8).empty;
    defer response_stream_payload.deinit(allocator);
    try http.appendHttp3Frame(&response_stream_payload, allocator, .headers, encoded_server_headers);
    try http.appendHttp3Frame(&response_stream_payload, allocator, .data, "hello-h3");

    var server_settings = std.ArrayList(u8).empty;
    defer server_settings.deinit(allocator);
    try http.encodeHttp3SettingsPayload(.{}, allocator, &server_settings);

    var control_stream_payload = std.ArrayList(u8).empty;
    defer control_stream_payload.deinit(allocator);
    try http.appendVarInt(&control_stream_payload, allocator, @intFromEnum(quic.Http3StreamType.control));
    try http.appendHttp3Frame(&control_stream_payload, allocator, .settings, server_settings.items);

    const client_cid = try quic.ConnectionId.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });
    const server_cid = try quic.ConnectionId.init(&[_]u8{ 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8 });

    const control_datagram = try buildHttp3DatagramForTest(
        allocator,
        client_cid,
        server_cid,
        1,
        3,
        0,
        false,
        control_stream_payload.items,
    );
    defer allocator.free(control_datagram);

    const response_datagram = try buildHttp3DatagramForTest(
        allocator,
        client_cid,
        server_cid,
        2,
        0,
        0,
        true,
        response_stream_payload.items,
    );
    defer allocator.free(response_datagram);

    const reads = [_][]const u8{ control_datagram, response_datagram };
    var transport = FakeHttp3Transport.init(allocator, &reads);
    defer transport.deinit();

    var response = try client.executeHttp3WithTransport(&req, &transport);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status.code);
    try std.testing.expectEqual(types.Version.HTTP_3, response.version);
    try std.testing.expectEqualStrings("text/plain", response.headers.get("content-type").?);
    try std.testing.expectEqualStrings("hello-h3", response.text().?);
    try std.testing.expect(transport.writes.items.len >= 2);
}

const FakeHttp2Transport = struct {
    allocator: Allocator,
    reads: []const u8,
    read_index: usize = 0,
    writes: std.ArrayList(u8) = .empty,

    fn init(allocator: Allocator, reads: []const u8) FakeHttp2Transport {
        return .{ .allocator = allocator, .reads = reads };
    }

    fn deinit(self: *FakeHttp2Transport) void {
        self.writes.deinit(self.allocator);
    }

    fn writeAll(self: *FakeHttp2Transport, data: []const u8) !void {
        try self.writes.appendSlice(self.allocator, data);
    }

    fn readNoEof(self: *FakeHttp2Transport, out: []u8) !void {
        if (self.read_index + out.len > self.reads.len) return error.UnexpectedEof;
        @memcpy(out, self.reads[self.read_index .. self.read_index + out.len]);
        self.read_index += out.len;
    }
};

const FakeHttp3Transport = struct {
    allocator: Allocator,
    reads: []const []const u8,
    read_index: usize = 0,
    writes: std.ArrayList([]u8) = .empty,

    fn init(allocator: Allocator, reads: []const []const u8) FakeHttp3Transport {
        return .{ .allocator = allocator, .reads = reads };
    }

    fn deinit(self: *FakeHttp3Transport) void {
        for (self.writes.items) |packet| {
            self.allocator.free(packet);
        }
        self.writes.deinit(self.allocator);
    }

    fn sendDatagram(self: *FakeHttp3Transport, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        try self.writes.append(self.allocator, copy);
    }

    fn recvDatagram(self: *FakeHttp3Transport, out: []u8) !usize {
        if (self.read_index >= self.reads.len) return error.UnexpectedEof;
        const packet = self.reads[self.read_index];
        self.read_index += 1;

        if (out.len < packet.len) return error.BufferTooSmall;
        @memcpy(out[0..packet.len], packet);
        return packet.len;
    }
};

fn buildHttp3DatagramForTest(
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

fn appendFrameBytes(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    frame_type: http.Http2FrameType,
    flags: u8,
    stream_id: u31,
    payload: []const u8,
) !void {
    const header = http.Http2FrameHeader{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = stream_id,
    };
    const raw = header.serialize();
    try out.appendSlice(allocator, &raw);
    try out.appendSlice(allocator, payload);
}

fn countWrittenHttp2Frames(data: []const u8, frame_type: http.Http2FrameType) usize {
    var count: usize = 0;
    var offset: usize = if (mem.startsWith(u8, data, http.HTTP2_PREFACE))
        http.HTTP2_PREFACE.len
    else
        0;

    while (offset + 9 <= data.len) {
        const length =
            (@as(usize, data[offset]) << 16) |
            (@as(usize, data[offset + 1]) << 8) |
            @as(usize, data[offset + 2]);
        const raw_type = data[offset + 3];
        offset += 9;

        if (offset + length > data.len) break;

        if (raw_type == @intFromEnum(frame_type)) {
            count += 1;
        }

        offset += length;
    }

    return count;
}
