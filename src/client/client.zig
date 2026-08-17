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
const proxy_mod = @import("proxy.zig");
const PoolStats = @import("pool.zig").PoolStats;
const common = @import("../util/common.zig");
const list_writer = @import("../util/list_writer.zig");
const io_util = @import("../util/any_io.zig");
const dbg = @import("../util/debug.zig");
const server_mod = @import("../server/server.zig");
const LogFn = server_mod.LogFn;

const defaultIo = io_util.defaultIo;
const sleepMs = io_util.sleepMs;

const RequestTimeouts = struct {
    connect_ms: u64,
    read_ms: u64,
    write_ms: u64,
};

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
    allow_push: bool = true,
    http2_settings: types.Http2Settings = .{},
    http3_settings: types.Http3Settings = .{},
    keep_alive: bool = true,
    pool_max_connections: u32 = 20,
    pool_max_per_host: u32 = 5,
    proxy: ?types.Proxy = null,
    unix_socket_path: ?[]const u8 = null,
    log_fn: ?LogFn = null,

    /// Returns default client configuration.
    pub fn defaults() ClientConfig {
        return .{};
    }

    /// Returns default configuration with a base URL.
    pub fn forBaseUrl(base_url: []const u8) ClientConfig {
        return .{ .base_url = base_url };
    }

    /// Returns a copy with a proxy configured.
    pub fn withProxy(self: ClientConfig, proxy: ?types.Proxy) ClientConfig {
        var out = self;
        out.proxy = proxy;
        return out;
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

    /// Returns a copy with a Unix domain socket path configured.
    pub fn withUnixSocket(self: ClientConfig, path: ?[]const u8) ClientConfig {
        var out = self;
        out.unix_socket_path = path;
        return out;
    }

    pub fn withLogFn(self: ClientConfig, log_fn: LogFn) ClientConfig {
        var config = self;
        config.log_fn = log_fn;
        return config;
    }

    /// Returns a copy with protocol runtime toggles.
    pub fn withProtocols(self: ClientConfig, http2_enabled: bool, http3_enabled: bool) ClientConfig {
        var out = self;
        out.http2_enabled = http2_enabled;
        out.http3_enabled = http3_enabled;
        return out;
    }

    /// Returns a copy with HTTP/2 server push allow/deny behavior.
    pub fn withAllowPush(self: ClientConfig, allow_push: bool) ClientConfig {
        var out = self;
        out.allow_push = allow_push;
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

/// Representation of a multipart form field.
pub const MultipartField = struct {
    name: []const u8,
    value: []const u8,
};

/// Representation of a multipart upload file.
pub const MultipartFile = struct {
    name: []const u8,
    filename: []const u8,
    content_type: ?[]const u8 = null,
    data: []const u8,
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
    connect_timeout_ms: ?u64 = null,
    read_timeout_ms: ?u64 = null,
    write_timeout_ms: ?u64 = null,
    timeouts: ?types.Timeouts = null,
    follow_redirects: ?bool = null,
    version: ?types.Version = null,
    multipart_fields: ?[]const MultipartField = null,
    multipart_files: ?[]const MultipartFile = null,
    multipart_boundary: ?[]const u8 = null,
    proxy: ?types.Proxy = null,
    verify_ssl: ?bool = null,
    keep_alive: ?bool = null,
    unix_socket_path: ?[]const u8 = null,

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

    /// Returns a copy with a custom proxy configuration for this request.
    pub fn withProxy(self: RequestOptions, proxy: ?types.Proxy) RequestOptions {
        var out = self;
        out.proxy = proxy;
        return out;
    }

    /// Returns a copy with explicit SSL verification behavior for this request.
    pub fn withSslVerification(self: RequestOptions, verify_ssl: bool) RequestOptions {
        var out = self;
        out.verify_ssl = verify_ssl;
        return out;
    }

    /// Returns a copy with explicit keep-alive behavior for this request.
    pub fn withKeepAlive(self: RequestOptions, keep_alive: bool) RequestOptions {
        var out = self;
        out.keep_alive = keep_alive;
        return out;
    }

    /// Returns a copy with a custom Unix domain socket path for this request.
    pub fn withUnixSocket(self: RequestOptions, path: ?[]const u8) RequestOptions {
        var out = self;
        out.unix_socket_path = path;
        return out;
    }

    /// Returns a copy with multipart fields.
    pub fn withMultipartFields(self: RequestOptions, fields: []const MultipartField) RequestOptions {
        var out = self;
        out.multipart_fields = fields;
        return out;
    }

    /// Returns a copy with multipart files.
    pub fn withMultipartFiles(self: RequestOptions, files: []const MultipartFile) RequestOptions {
        var out = self;
        out.multipart_files = files;
        return out;
    }

    /// Returns a copy with a custom boundary for multipart request.
    pub fn withMultipartBoundary(self: RequestOptions, boundary: []const u8) RequestOptions {
        var out = self;
        out.multipart_boundary = boundary;
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

    /// Returns a copy with a per-request uniform timeout across connect/read/write phases.
    pub fn withTimeoutMs(self: RequestOptions, timeout_ms: u64) RequestOptions {
        var out = self;
        out.timeout_ms = timeout_ms;
        return out;
    }

    /// Returns a copy with explicit per-phase timeouts struct.
    pub fn withTimeouts(self: RequestOptions, timeouts: types.Timeouts) RequestOptions {
        var out = self;
        out.timeouts = timeouts;
        return out;
    }

    /// Returns a copy with explicit connect phase timeout in milliseconds.
    pub fn withConnectTimeoutMs(self: RequestOptions, connect_timeout_ms: u64) RequestOptions {
        var out = self;
        out.connect_timeout_ms = connect_timeout_ms;
        return out;
    }

    /// Returns a copy with explicit read phase timeout in milliseconds.
    pub fn withReadTimeoutMs(self: RequestOptions, read_timeout_ms: u64) RequestOptions {
        var out = self;
        out.read_timeout_ms = read_timeout_ms;
        return out;
    }

    /// Returns a copy with explicit write phase timeout in milliseconds.
    pub fn withWriteTimeoutMs(self: RequestOptions, write_timeout_ms: u64) RequestOptions {
        var out = self;
        out.write_timeout_ms = write_timeout_ms;
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
        dbg.entry("CLIENT", "initWithConfig");
        defer dbg.exit("CLIENT", "initWithConfig");
        return .{
            .allocator = allocator,
            .config = config,
            .pool = ConnectionPool.initWithConfig(allocator, .{
                .max_connections = config.pool_max_connections,
                .max_per_host = config.pool_max_per_host,
                .connect_timeout_ms = config.timeouts.connect_ms,
            }),
        };
    }

    /// Creates a new client with default settings and a base URL.
    pub fn initForBaseUrl(allocator: Allocator, base_url: []const u8) Self {
        return initWithConfig(allocator, ClientConfig.forBaseUrl(base_url));
    }

    /// Releases all allocated resources.
    pub fn deinit(self: *Self) void {
        dbg.entry("CLIENT", "deinit");
        defer dbg.exit("CLIENT", "deinit");
        self.interceptors.deinit(self.allocator);
        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.deinit(self.allocator);
        self.pool.deinit();
    }

    /// Logs a formatted message. If config.log_fn is provided, delegates to it.
    /// Otherwise, falls back to stderr.
    pub fn log(self: *const Self, level: server_mod.LogLevel, comptime format: []const u8, args: anytype) void {
        if (self.config.log_fn) |log_fn| {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, format, args)) |msg| {
                log_fn(level, msg);
            } else |_| {
                log_fn(level, "[Log format failed or message too long]");
            }
        }
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
    pub fn poolStats(self: *Self) PoolStats {
        return self.pool.stats();
    }

    /// Returns how many pooled connections are tracked for a host/port.
    pub fn hostPoolConnectionCount(self: *Self, host: []const u8, port: u16) usize {
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
        dbg.entry("CLIENT", "requestInternal");
        dbg.log("CLIENT", "method={s} url={s} depth={d}", .{ @tagName(method), url, depth });
        defer dbg.exit("CLIENT", "requestInternal");
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
        if (!req.headers.contains("Accept-Encoding")) {
            try req.headers.set("Accept-Encoding", "gzip, deflate, br, zstd, identity");
        }

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
        } else if (reqOpts.multipart_fields != null or reqOpts.multipart_files != null) {
            const boundary = reqOpts.multipart_boundary orelse "----httpxBoundary1234567890";
            var builder = @import("../util/multipart.zig").MultipartBuilder.init(self.allocator, boundary);
            defer builder.deinit();

            if (reqOpts.multipart_fields) |fields| {
                for (fields) |field| {
                    try builder.addField(field.name, field.value);
                }
            }

            if (reqOpts.multipart_files) |files| {
                for (files) |file| {
                    const resolved_mime = file.content_type orelse common.mimeTypeFromPathOr(file.filename, "application/octet-stream");

                    try builder.addFile(file.name, file.filename, resolved_mime, file.data);
                }
            }

            const body = try builder.build();
            defer self.allocator.free(body);
            try req.setBody(body);

            const ct = try builder.contentType();
            defer self.allocator.free(ct);
            try req.headers.set(HeaderName.CONTENT_TYPE, ct);
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

        var response = try self.executeRequest(&req, reqOpts);
        try self.storeCookies(&response, req.uri.host orelse "");

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
    fn executeRequest(self: *Self, req: *Request, reqOpts: RequestOptions) !Response {
        dbg.entry("CLIENT", "executeRequest");
        defer dbg.exit("CLIENT", "executeRequest");
        const policy = self.config.retry_policy;
        const can_retry_method = (!policy.retry_only_idempotent) or req.method.isIdempotent();

        var attempt: u32 = 0;
        while (true) {
            var res = self.executeRequestOnce(req, reqOpts) catch |err| {
                if (policy.retry_on_connection_error and can_retry_method and attempt < policy.max_retries and isRetryableRequestError(err)) {
                    attempt += 1;
                    dbg.log("CLIENT", "retry attempt={d} after error", .{attempt});
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

    fn formatProxyRequest(self: *Self, req: *const Request, proxy: types.Proxy) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(self.allocator, &buffer);

        const method_str = req.method.toString();
        // Construct absolute URI
        try writer.print("{s} http://{s}:{d}{s}", .{ method_str, req.uri.host orelse "", req.uri.effectivePort(), req.uri.path });
        if (req.uri.query) |q| {
            try writer.print("?{s}", .{q});
        }
        try writer.print(" {s}\r\n", .{req.version.toString()});

        for (req.headers.entries.items) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        if (proxy.username) |user| {
            const pass = proxy.password orelse "";
            const auth_val = try @import("../util/encoding.zig").Base64.formatBasicAuth(self.allocator, user, pass);
            defer self.allocator.free(auth_val);
            try writer.print("Proxy-Authorization: {s}\r\n", .{auth_val});
        }

        try writer.writeAll("\r\n");

        if (req.body) |body| {
            try writer.writeAll(body);
        }

        return buffer.toOwnedSlice(self.allocator);
    }

    fn establishProxyTlsTunnel(self: *Self, socket: *Socket, target_host: []const u8, target_port: u16, proxy: types.Proxy) !void {
        dbg.entry("CLIENT", "establishProxyTlsTunnel");
        defer dbg.exit("CLIENT", "establishProxyTlsTunnel");
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(self.allocator, &buffer);

        try writer.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ target_host, target_port, target_host, target_port });

        if (proxy.username) |user| {
            const pass = proxy.password orelse "";
            const auth_val = try @import("../util/encoding.zig").Base64.formatBasicAuth(self.allocator, user, pass);
            defer self.allocator.free(auth_val);
            try writer.print("Proxy-Authorization: {s}\r\n", .{auth_val});
        }
        try writer.writeAll("\r\n");

        const connect_req = try buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(connect_req);

        try socket.sendAll(connect_req);

        var response = try self.readResponseFromTcp(socket, true);
        defer response.deinit();

        if (response.status.code < 200 or response.status.code >= 300) {
            return error.ProxyConnectionFailed;
        }
    }

    fn resolveRequestTimeouts(self: *const Self, req_opts: RequestOptions) RequestTimeouts {
        var connect_ms = self.config.timeouts.connect_ms;
        var read_ms = self.config.timeouts.read_ms;
        var write_ms = self.config.timeouts.write_ms;

        if (req_opts.timeouts) |t| {
            connect_ms = t.connect_ms;
            read_ms = t.read_ms;
            write_ms = t.write_ms;
        }

        if (req_opts.timeout_ms) |ms| {
            connect_ms = ms;
            read_ms = ms;
            write_ms = ms;
        }

        if (req_opts.connect_timeout_ms) |c_ms| connect_ms = c_ms;
        if (req_opts.read_timeout_ms) |r_ms| read_ms = r_ms;
        if (req_opts.write_timeout_ms) |w_ms| write_ms = w_ms;

        return .{
            .connect_ms = connect_ms,
            .read_ms = read_ms,
            .write_ms = write_ms,
        };
    }

    fn executeRequestOnce(self: *Self, req: *Request, reqOpts: RequestOptions) !Response {
        dbg.entry("CLIENT", "executeRequestOnce");
        defer dbg.exit("CLIENT", "executeRequestOnce");
        const timeouts = self.resolveRequestTimeouts(reqOpts);
        const proxy = reqOpts.proxy orelse self.config.proxy;
        const keep_alive = reqOpts.keep_alive orelse self.config.keep_alive;
        const verify_ssl = reqOpts.verify_ssl orelse self.config.verify_ssl;
        const unix_socket_path = reqOpts.unix_socket_path orelse self.config.unix_socket_path;

        if (unix_socket_path) |path| {
            const unix_mod = @import("../net/unix.zig");
            const unix_sock = try unix_mod.UnixClient.connect(path);
            var socket = Socket.fromHandle(unix_sock.fd);
            defer socket.close();

            if (timeouts.read_ms > 0) {
                try socket.setRecvTimeout(timeouts.read_ms);
            }
            if (timeouts.write_ms > 0) {
                try socket.setSendTimeout(timeouts.write_ms);
            }

            const request_data = try http.formatRequest(req, self.allocator);
            defer self.allocator.free(request_data);

            try socket.sendAll(request_data);
            return self.readResponseFromTcp(&socket, req.method.hasResponseBody());
        }

        const host = req.uri.host orelse return error.InvalidUri;
        const port = req.uri.effectivePort();

        const wants_http2 = self.config.http2_enabled or req.version == .HTTP_2;
        const wants_http3 = self.config.http3_enabled or req.version == .HTTP_3;

        // HTTP/3 takes priority, but falls back to HTTP/2 when a proxy is
        // configured (QUIC does not support standard HTTP proxies).
        if (wants_http3) {
            if (proxy != null) {
                // Fall back to HTTP/2 if also enabled; otherwise return error.
                if (wants_http2) {
                    return self.executeRequestHttp2(req, host, port, timeouts, reqOpts);
                }
                return error.ProxyNotSupported;
            }
            return self.executeRequestHttp3(req, host, port, timeouts, reqOpts);
        }

        if (wants_http2) {
            return self.executeRequestHttp2(req, host, port, timeouts, reqOpts);
        }

        var request_data: []u8 = undefined;
        if (proxy) |p| {
            if (p.kind == .http and !req.uri.isTls()) {
                request_data = try self.formatProxyRequest(req, p);
            } else {
                request_data = try http.formatRequest(req, self.allocator);
            }
        } else {
            request_data = try http.formatRequest(req, self.allocator);
        }
        defer self.allocator.free(request_data);

        if (req.uri.isTls()) {
            dbg.log("CLIENT", "TLS path for {s}:{d}", .{ host, port });
            dbg.log("CLIENT", "direct path for {s}:{d}", .{ host, port });
            const connect_host = if (proxy) |p| p.host else host;
            const connect_port = if (proxy) |p| p.port else port;
            const addr = try address_mod.resolve(self.allocator, connect_host, connect_port);

            var socket = try Socket.createForAddress(addr);
            defer socket.close();

            // Do not set SO_RCVTIMEO / SO_SNDTIMEO on TLS sockets.
            // The TLS layer performs multi-step record I/O; a per-recv
            // timeout fires mid-handshake and kills the TLS state
            // machine.  The connect timeout is handled separately by
            // connectWithTimeout (which uses poll).
            try socket.setNoDelay(true);

            try socket.connectWithTimeout(addr, timeouts.connect_ms);

            if (proxy) |p| {
                if (p.kind == .socks5h) {
                    try proxy_mod.establishSocks5hTunnel(&socket, host, port, p);
                } else {
                    try self.establishProxyTlsTunnel(&socket, host, port, p);
                }
            }

            return self.executeTlsHttp(&socket, host, port, request_data, verify_ssl);
        }

        if (keep_alive) {
            dbg.log("CLIENT", "pool path for {s}:{d}", .{ host, port });
            var conn = try self.pool.getConnection(host, port, proxy, timeouts.connect_ms);
            errdefer conn.close();
            defer self.pool.releaseConnection(conn);

            if (timeouts.read_ms > 0) {
                try conn.socket.setRecvTimeout(timeouts.read_ms);
            }
            if (timeouts.write_ms > 0) {
                try conn.socket.setSendTimeout(timeouts.write_ms);
            }
            try conn.socket.setKeepAlive(true);

            try conn.socket.sendAll(request_data);
            var res = try self.readResponseFromTcp(&conn.socket, req.method.hasResponseBody());
            if (!res.headers.isKeepAlive(res.version)) {
                self.pool.closeConnection(conn);
            }
            return res;
        }

        const connect_host = if (proxy) |p| p.host else host;
        const connect_port = if (proxy) |p| p.port else port;
        const addr = try address_mod.resolve(self.allocator, connect_host, connect_port);

        var socket = try Socket.createForAddress(addr);
        defer socket.close();

        if (timeouts.read_ms > 0) {
            try socket.setRecvTimeout(timeouts.read_ms);
        }
        if (timeouts.write_ms > 0) {
            try socket.setSendTimeout(timeouts.write_ms);
        }

        try socket.connectWithTimeout(addr, timeouts.connect_ms);

        if (proxy) |p| {
            if (p.kind == .socks5h) {
                try proxy_mod.establishSocks5hTunnel(&socket, host, port, p);
            }
        }

        try socket.sendAll(request_data);
        return self.readResponseFromTcp(&socket, req.method.hasResponseBody());
    }

    fn executeRequestHttp2(
        self: *Self,
        req: *Request,
        host: []const u8,
        port: u16,
        timeouts: RequestTimeouts,
        reqOpts: RequestOptions,
    ) !Response {
        dbg.entry("CLIENT", "executeRequestHttp2");
        defer dbg.exit("CLIENT", "executeRequestHttp2");
        const proxy = reqOpts.proxy orelse self.config.proxy;
        const verify_ssl = reqOpts.verify_ssl orelse self.config.verify_ssl;

        const connect_host = if (proxy) |p| p.host else host;
        const connect_port = if (proxy) |p| p.port else port;
        const addr = try address_mod.resolve(self.allocator, connect_host, connect_port);

        var socket = try Socket.createForAddress(addr);
        defer socket.close();

        // Do not set SO_RCVTIMEO / SO_SNDTIMEO on sockets used for
        // TLS -- the TLS layer performs multi-step record I/O and a
        // per-recv timeout fires mid-handshake.  The connect timeout
        // is handled separately by connectWithTimeout.

        try socket.connectWithTimeout(addr, timeouts.connect_ms);

        if (proxy) |p| {
            if (p.kind == .socks5h) {
                try proxy_mod.establishSocks5hTunnel(&socket, host, port, p);
            } else {
                try self.establishProxyTlsTunnel(&socket, host, port, p);
            }
        }

        if (req.uri.isTls()) {
            // Build ALPN list based on enabled protocols.
            // When both HTTP/2 and HTTP/3 are enabled, advertise all three.
            const tls_session_cfg = blk: {
                if (self.config.http3_enabled and self.config.http2_enabled) {
                    break :blk if (verify_ssl)
                        TlsConfig.withH3(self.allocator)
                    else
                        TlsConfig.insecureWithH3(self.allocator);
                } else if (verify_ssl) {
                    break :blk TlsConfig.withH2(self.allocator);
                } else {
                    break :blk TlsConfig.insecureWithH2(self.allocator);
                }
            };
            var session = TlsSession.init(tls_session_cfg);
            defer session.deinit();
            session.attachSocket(&socket);
            try session.handshake(host);

            // Set recv timeout after TLS handshake completes so the
            // HTTP/2 preface exchange does not hang indefinitely.
            if (timeouts.read_ms > 0) {
                try socket.setRecvTimeout(timeouts.read_ms);
            }

            const negotiated = http.negotiateVersion(session.negotiatedProtocol());
            switch (negotiated) {
                .http_2 => {
                    var transport = TlsHttp2Transport{ .session = &session };
                    return self.executeHttp2WithTransport(req, &transport);
                },
                .http_3 => {
                    // Server selected h3 via ALPN.  For TLS-based connections
                    // (TCP), HTTP/3 negotiation means the server prefers QUIC
                    // but we are on a TCP socket.  Attempt to upgrade via
                    // Alt-Svc or fall back to HTTP/2 if available.
                    if (self.config.http2_enabled) {
                        var transport = TlsHttp2Transport{ .session = &session };
                        return self.executeHttp2WithTransport(req, &transport);
                    }
                    return error.UnsupportedHttpVersion;
                },
                .http_1_1, .http_1_0 => {
                    // Server selected http/1.1 via ALPN (or ALPN was
                    // unavailable).  Fall back to HTTP/1.1 over the
                    // already-established TLS session.
                    const request_data = try http.formatRequest(req, self.allocator);
                    defer self.allocator.free(request_data);

                    try session.writeAll(request_data);
                    try session.flush();

                    return self.readResponseFromTls(&session, req.method.hasResponseBody());
                },
            }
        }

        var transport = SocketHttp2Transport{ .socket = &socket };

        // Set recv timeout for the HTTP/2 preface exchange so we
        // do not hang if the server never responds.
        if (timeouts.read_ms > 0) {
            try socket.setRecvTimeout(timeouts.read_ms);
        }

        return self.executeHttp2WithTransport(req, &transport);
    }

    fn executeRequestHttp3(
        self: *Self,
        req: *Request,
        host: []const u8,
        port: u16,
        timeouts: RequestTimeouts,
        reqOpts: RequestOptions,
    ) !Response {
        dbg.entry("CLIENT", "executeRequestHttp3");
        defer dbg.exit("CLIENT", "executeRequestHttp3");
        _ = reqOpts;
        const addr = try address_mod.resolve(self.allocator, host, port);

        var socket = try UdpSocket.createForAddress(addr);
        defer socket.close();

        if (timeouts.read_ms > 0) {
            try socket.setRecvTimeout(timeouts.read_ms);
        }
        if (timeouts.write_ms > 0) {
            try socket.setSendTimeout(timeouts.write_ms);
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

        // HTTP/3 flow control state
        var conn_max_data: u64 = 10 * 1024 * 1024; // 10 MB default
        var conn_data_sent: u64 = 0;
        var stream_max_data: u64 = 1024 * 1024; // 1 MB default per stream
        var stream_data_sent: u64 = 0;

        var path_buf: ?[]u8 = null;
        defer if (path_buf) |buf| self.allocator.free(buf);
        var authority_buf: ?[]u8 = null;
        defer if (authority_buf) |buf| self.allocator.free(buf);

        var header_entries = std.ArrayList(qpack.HeaderEntry).empty;
        defer header_entries.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| self.allocator.free(name);
            owned_header_names.deinit(self.allocator);
        }

        try buildPseudoHeaders(self.allocator, req, &header_entries, &owned_header_names, &path_buf, &authority_buf);

        const headers_block = try qpack.encodeHeaders(&qpack_encoder, header_entries.items, self.allocator);
        defer self.allocator.free(headers_block);

        var request_stream_payload = std.ArrayList(u8).empty;
        defer request_stream_payload.deinit(self.allocator);
        try http.appendHttp3Frame(&request_stream_payload, self.allocator, .headers, headers_block);

        if (req.body) |body| {
            if (body.len > 0) {
                // Check connection and stream flow control limits
                if (conn_data_sent + body.len > conn_max_data) return error.FlowControlError;
                if (stream_data_sent + body.len > stream_max_data) return error.FlowControlError;
                try http.appendHttp3Frame(&request_stream_payload, self.allocator, .data, body);
                conn_data_sent += body.len;
                stream_data_sent += body.len;
            }
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
            try http.appendVarInt(&max_stream_data_payload, self.allocator, 0); // stream_id 0
            try http.appendVarInt(&max_stream_data_payload, self.allocator, stream_max_data);
            try http.appendHttp3Frame(&control_stream_payload, self.allocator, .max_stream_data, max_stream_data_payload.items);
        }

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
            &conn_max_data,
            &stream_max_data,
            &got_response_fin,
        );

        const final_status = status_code orelse return error.InvalidResponse;

        var response = Response.init(self.allocator, final_status);
        errdefer response.deinit();
        response.version = .HTTP_3;

        response.headers.deinit();
        response.headers = response_headers;
        response_headers = Headers.init(self.allocator);

        if (response_body.items.len > 0) {
            // Decompress body based on Content-Encoding header (HTTP/3).
            if (response.headers.get(HeaderName.CONTENT_ENCODING)) |encoding_str| {
                if (@import("../util/compression.zig").ContentEncoding.fromString(encoding_str)) |enc| {
                    if (enc != .identity) {
                        if (@import("../util/compression.zig").decompress(self.allocator, enc, response_body.items)) |decompressed| {
                            response.body = decompressed;
                            response.body_owned = true;
                            return response;
                        } else |_| {}
                    }
                }
            }
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
        conn_max_data: *u64,
        stream_max_data: *u64,
        got_response_fin: *bool,
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
                @intFromEnum(http.Http3FrameType.goaway) => {
                    // Gracefully handle GOAWAY: finish current stream processing
                    if (status_code.* != null) {
                        got_response_fin.* = true;
                    }
                },
                @intFromEnum(http.Http3FrameType.max_data) => {
                    if (frame_payload.len > 0) {
                        const val = try http.decodeVarInt(frame_payload);
                        conn_max_data.* = val.value;
                    }
                },
                @intFromEnum(http.Http3FrameType.max_stream_data) => {
                    if (frame_payload.len > 0) {
                        // stream_id varint + data_limit varint; update the relevant stream
                        const sid = try http.decodeVarInt(frame_payload);
                        const data_limit = try http.decodeVarInt(frame_payload[sid.len..]);
                        stream_max_data.* = data_limit.value;
                    }
                },
                else => {
                    // Unknown/unsupported frame types are ignored for forward compatibility.
                },
            }
        }
    }

    /// A frame buffered during the H2 body-upload flow-control pump phase.
    /// Freed by the caller after replaying in the response loop.
    const EarlyH2Frame = struct {
        header: http.Http2FrameHeader,
        payload: []u8,

        fn deinit(self: *EarlyH2Frame, allocator: Allocator) void {
            allocator.free(self.payload);
        }
    };

    /// A frame read by the H2 response loop -- wraps either a freshly-read frame
    /// (owned) or a replayed early frame (not owned by this value).
    const H2Frame = struct {
        header: http.Http2FrameHeader,
        payload: []u8,
        from_early_buf: bool,
    };

    /// Pumps incoming HTTP/2 frames until the send window is positive.
    ///
    /// Called when `request_stream.send_window` or
    /// `stream_manager.connection_send_window` reaches zero mid-body upload.
    /// Processes WINDOW_UPDATE, SETTINGS, and PING frames to grow the send window.
    /// Early response frames (HEADERS/DATA/CONTINUATION) are appended to
    /// `early_frames` so the response loop can replay them without data loss.
    ///
    /// Returns `error.GoAway` if the server sends GOAWAY, or
    /// `error.StreamError` if the server resets the request stream.
    /// Returns `error.ProtocolError` if more than 10,000 frames are processed
    /// without the window being granted.
    fn pumpUntilSendWindow(
        self: *Client,
        transport: anytype,
        stream_manager: *h2stream.StreamManager,
        request_stream: *h2stream.Stream,
        peer_max_frame_size: *u32,
        early_frames: *std.ArrayList(EarlyH2Frame),
    ) !void {
        var pump_counter: usize = 0;
        while (request_stream.send_window <= 0 or stream_manager.connection_send_window <= 0) {
            pump_counter += 1;
            if (pump_counter > 10_000) return error.ProtocolError;

            var hdr_bytes: [9]u8 = undefined;
            try transport.readNoEof(&hdr_bytes);
            const fhdr = http.Http2FrameHeader.parse(hdr_bytes);

            const payload_len: usize = @intCast(fhdr.length);
            if (payload_len > self.config.max_response_size) return error.FrameTooLarge;

            const payload = try self.allocator.alloc(u8, payload_len);
            errdefer self.allocator.free(payload);
            if (payload_len > 0) try transport.readNoEof(payload);

            switch (fhdr.frame_type) {
                .window_update => {
                    if (payload.len != 4) {
                        self.allocator.free(payload);
                        return error.ProtocolError;
                    }
                    const increment = ((@as(u32, payload[0] & 0x7F) << 24) |
                        (@as(u32, payload[1]) << 16) |
                        (@as(u32, payload[2]) << 8) |
                        payload[3]);
                    self.allocator.free(payload);
                    if (increment == 0) return error.ProtocolError;
                    if (fhdr.stream_id == 0) {
                        // Connection-level WINDOW_UPDATE.
                        stream_manager.connection_send_window += @intCast(increment);
                    } else if (fhdr.stream_id == request_stream.id) {
                        // Stream-level WINDOW_UPDATE.
                        request_stream.send_window += @intCast(increment);
                    }
                    // If both windows are positive now, we can stop pumping.
                },
                .settings => {
                    const is_ack = (fhdr.flags & 0x01) != 0;
                    if (!is_ack and fhdr.stream_id == 0) {
                        var peer_settings = http.Http2Connection.Http2ConnectionSettings{};
                        http.applySettingsPayload(&peer_settings, payload) catch return error.Http2ProtocolError;
                        stream_manager.applyPeerSettings(peer_settings) catch return error.Http2ProtocolError;
                        peer_max_frame_size.* = peer_settings.max_frame_size;
                        // Send SETTINGS ACK.
                        writeHttp2Frame(transport, .settings, 0x01, 0, &.{}) catch return error.WriteFailed;
                    }
                    self.allocator.free(payload);
                },
                .ping => {
                    const is_ack = (fhdr.flags & 0x01) != 0;
                    if (!is_ack and fhdr.stream_id == 0 and payload.len == 8) {
                        writeHttp2Frame(transport, .ping, 0x01, 0, payload) catch return error.WriteFailed;
                    }
                    self.allocator.free(payload);
                },
                .goaway => {
                    self.allocator.free(payload);
                    return error.GoAway;
                },
                .rst_stream => {
                    if (fhdr.stream_id == request_stream.id) {
                        self.allocator.free(payload);
                        return error.StreamError;
                    }
                    self.allocator.free(payload);
                },
                .priority => {
                    self.allocator.free(payload);
                },
                .headers, .data, .continuation, .push_promise => {
                    // Early response frame -- buffer for replay in the response loop.
                    try early_frames.append(self.allocator, .{
                        .header = fhdr,
                        .payload = payload,
                    });
                },
                // RFC 7540 4.1: Unknown frame types MUST be ignored.
                _ => {
                    self.allocator.free(payload);
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

        const local_settings = toConnectionSettings(self.config.http2_settings, self.config.allow_push);
        try http.encodeSettingsPayload(local_settings, self.allocator, &settings_payload);
        try writeHttp2Frame(transport, .settings, 0, 0, settings_payload.items);

        const request_stream = try stream_manager.createStream();
        try request_stream.open();

        var path_buf: ?[]u8 = null;
        defer if (path_buf) |buf| self.allocator.free(buf);
        var authority_buf: ?[]u8 = null;
        defer if (authority_buf) |buf| self.allocator.free(buf);

        var header_entries = std.ArrayList(hpack.HeaderEntry).empty;
        defer header_entries.deinit(self.allocator);

        var owned_header_names = std.ArrayList([]u8).empty;
        defer {
            for (owned_header_names.items) |name| self.allocator.free(name);
            owned_header_names.deinit(self.allocator);
        }

        try buildPseudoHeaders(self.allocator, req, &header_entries, &owned_header_names, &path_buf, &authority_buf);

        const has_body = req.body != null and req.body.?.len > 0;
        const headers_frames = try h2stream.buildHeadersAndContinuations(
            &stream_manager,
            request_stream.id,
            header_entries.items,
            null,
            local_settings.max_frame_size,
            !has_body,
            self.allocator,
        );
        defer self.allocator.free(headers_frames);

        try transport.writeAll(headers_frames);

        var peer_max_frame_size: u32 = local_settings.max_frame_size;

        // Buffered early-response frames received during the body upload phase
        // (when we pump for WINDOW_UPDATE). These are replayed at the start of
        // the response loop so no frames are dropped.
        var early_frames = std.ArrayList(EarlyH2Frame).empty;
        defer {
            for (early_frames.items) |*ef| ef.deinit(self.allocator);
            early_frames.deinit(self.allocator);
        }

        if (has_body) {
            const body = req.body.?;
            var offset: usize = 0;
            while (offset < body.len) {
                // If either the stream or connection send window is exhausted,
                // pump incoming frames until we get enough WINDOW_UPDATE credit
                // rather than immediately failing with FlowControlError.
                if (request_stream.send_window <= 0 or stream_manager.connection_send_window <= 0) {
                    try pumpUntilSendWindow(
                        self,
                        transport,
                        &stream_manager,
                        request_stream,
                        &peer_max_frame_size,
                        &early_frames,
                    );
                }
                const window_stream = @as(i64, request_stream.send_window);
                const window_conn = @as(i64, stream_manager.connection_send_window);
                if (window_stream <= 0 or window_conn <= 0) return error.FlowControlError;
                const max_chunk = @min(
                    @as(usize, @intCast(window_stream)),
                    @as(usize, @intCast(window_conn)),
                );
                const chunk_len = @min(body.len - offset, max_chunk, @as(usize, @intCast(peer_max_frame_size)));
                const is_last = offset + chunk_len == body.len;
                const chunk_flags: u8 = if (is_last) 0x01 else 0;
                try writeHttp2Frame(
                    transport,
                    .data,
                    chunk_flags,
                    request_stream.id,
                    body[offset .. offset + chunk_len],
                );
                request_stream.send_window -= @intCast(chunk_len);
                stream_manager.connection_send_window -= @intCast(chunk_len);
                offset += chunk_len;
            }
            request_stream.sendEndStream();
        } else {
            request_stream.sendEndStream();
        }

        var response_headers = Headers.init(self.allocator);
        defer response_headers.deinit();

        var trailers = Headers.init(self.allocator);
        defer trailers.deinit();

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);

        var pending_headers_block = std.ArrayList(u8).empty;
        defer pending_headers_block.deinit(self.allocator);

        var pending_headers_flags: u8 = 0;
        var waiting_continuation = false;

        var status_code: ?u16 = null;
        var response_done = false;
        var got_end_stream = false;

        var peer_settings = http.Http2Connection.Http2ConnectionSettings{};

        // Replay buffered early-response frames collected during body upload
        // (pumpUntilSendWindow may have buffered them).  We process them first
        // so the loop below sees a logically complete frame stream.
        var early_frame_idx: usize = 0;

        var frame_counter: usize = 0;
        while (!response_done) {
            frame_counter += 1;
            if (frame_counter > 10_000) return error.ProtocolError;

            // Consume buffered early frames before reading from the transport.
            const frame: H2Frame = blk: {
                if (early_frame_idx < early_frames.items.len) {
                    const ef = &early_frames.items[early_frame_idx];
                    early_frame_idx += 1;
                    break :blk H2Frame{
                        .header = ef.header,
                        .payload = ef.payload,
                        .from_early_buf = true,
                    };
                }
                break :blk self.readHttp2Frame(transport) catch |err| switch (err) {
                    error.UnexpectedEof => {
                        // RFC 7540 6.8: a server may close the connection
                        // after sending the final frame. If we already received a
                        // complete response (END_STREAM seen, status code present),
                        // treat the clean close as end-of-response rather than error.
                        if (got_end_stream and status_code != null) {
                            response_done = true;
                            continue;
                        }
                        return error.InvalidResponse;
                    },
                    else => return err,
                };
            };
            // Only free payload for frames we allocated ourselves (not early buf replays).
            defer if (!frame.from_early_buf) self.allocator.free(frame.payload);

            switch (frame.header.frame_type) {
                .settings => {
                    if (frame.header.stream_id != 0) return error.ProtocolError;
                    const is_ack = (frame.header.flags & 0x01) != 0;
                    if (!is_ack) {
                        try http.applySettingsPayload(&peer_settings, frame.payload);
                        try stream_manager.applyPeerSettings(peer_settings);
                        peer_max_frame_size = peer_settings.max_frame_size;
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
                    response_done = true;
                },
                .window_update, .priority => {},
                .push_promise => {
                    if (frame.header.stream_id == 0) return error.ProtocolError;
                    if (!self.config.allow_push) {
                        const promised_stream_id = (@as(u31, frame.payload[0] & 0x7F) << 24) |
                            (@as(u31, frame.payload[1]) << 16) |
                            (@as(u31, frame.payload[2]) << 8) |
                            frame.payload[3];
                        const rst_frame = h2stream.buildRstStreamFrame(promised_stream_id, .refused_stream);
                        try transport.writeAll(&rst_frame);
                    }
                },
                .rst_stream => {
                    if (frame.header.stream_id == request_stream.id) {
                        if (!got_end_stream) {
                            const rst_frame = h2stream.buildRstStreamFrame(request_stream.id, .cancel);
                            try transport.writeAll(&rst_frame);
                            return error.StreamError;
                        }
                        response_done = true;
                    }
                },
                .headers => {
                    if (frame.header.stream_id != request_stream.id) continue;

                    if (got_end_stream) {
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
                                if (header.name.len > 0 and header.name[0] == ':') continue;
                                if (common.isConnectionSpecificHeader(header.name)) continue;
                                try trailers.append(header.name, header.value);
                            }
                            response_done = true;
                        } else {
                            pending_headers_flags = frame.header.flags;
                            try pending_headers_block.appendSlice(self.allocator, frame.payload);
                            waiting_continuation = true;
                        }
                        continue;
                    }

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
                            got_end_stream = true;
                            request_stream.receiveEndStream();
                            // Fix: terminate the response loop immediately when
                            // END_STREAM is set on a HEADERS frame and we have
                            // a status code. Without this, the loop keeps
                            // reading frames from keep-alive servers until the
                            // recv timeout fires (causing a hang or ProtocolError).
                            if (status_code != null) response_done = true;
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
                        if (got_end_stream) {
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
                                if (header.name.len > 0 and header.name[0] == ':') continue;
                                if (common.isConnectionSpecificHeader(header.name)) continue;
                                try trailers.append(header.name, header.value);
                            }
                            pending_headers_block.clearRetainingCapacity();
                            waiting_continuation = false;
                            response_done = true;
                        } else {
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
                                got_end_stream = true;
                                request_stream.receiveEndStream();
                                // Fix: terminate on END_STREAM from CONTINUATION.
                                if (status_code != null) response_done = true;
                            }
                        }
                    }
                },
                .data => {
                    if (frame.header.stream_id != request_stream.id) continue;

                    if (got_end_stream) continue;

                    if (frame.header.length > local_settings.max_frame_size) return error.FrameTooLarge;

                    var data_slice = frame.payload;
                    if ((frame.header.flags & 0x08) != 0) {
                        if (frame.payload.len == 0) return error.ProtocolError;
                        const pad_len = frame.payload[0];
                        if (frame.payload.len < @as(usize, pad_len) + 1) return error.ProtocolError;
                        data_slice = frame.payload[1 .. frame.payload.len - pad_len];
                    }

                    if (body.items.len + data_slice.len > self.config.max_response_size) return error.ResponseTooLarge;
                    try body.appendSlice(self.allocator, data_slice);

                    if (data_slice.len > 0) {
                        const window_increment: u31 = @intCast(data_slice.len);
                        const window_update = h2stream.buildWindowUpdatePayload(window_increment);
                        try writeHttp2Frame(transport, .window_update, 0, request_stream.id, &window_update);
                        try writeHttp2Frame(transport, .window_update, 0, 0, &window_update);
                    }

                    if ((frame.header.flags & 0x01) != 0) {
                        got_end_stream = true;
                        request_stream.receiveEndStream();
                        // Fix: terminate the response loop immediately when
                        // END_STREAM is set on a DATA frame and we have a
                        // status code. Without this, the loop keeps reading
                        // from keep-alive servers until the recv timeout fires.
                        if (status_code != null) response_done = true;
                    }
                },
                // RFC 7540 4.1: Unknown frame types MUST be ignored.
                _ => {},
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

        if (trailers.count() > 0) {
            response.trailers = trailers;
            trailers = Headers.init(self.allocator);
        }

        if (body.items.len > 0) {
            // Decompress body based on Content-Encoding header (HTTP/2).
            if (response_headers.get(HeaderName.CONTENT_ENCODING)) |encoding_str| {
                if (@import("../util/compression.zig").ContentEncoding.fromString(encoding_str)) |enc| {
                    if (enc != .identity) {
                        if (@import("../util/compression.zig").decompress(self.allocator, enc, body.items)) |decompressed| {
                            response.body = decompressed;
                            response.body_owned = true;
                            return response;
                        } else |_| {}
                    }
                }
            }
            response.body = try body.toOwnedSlice(self.allocator);
            response.body_owned = true;
        }

        return response;
    }

    fn readHttp2Frame(self: *Self, transport: anytype) !H2Frame {
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

        return .{ .header = header, .payload = payload, .from_early_buf = false };
    }

    /// Context for TLS version fallback reconnection.
    /// When TLS 1.3 fails and the server closes the TCP connection,
    /// the reconnect callback creates a fresh socket for the TLS 1.2 retry.
    const ReconnectContext = struct {
        allocator: Allocator,
        host: []const u8,
        port: u16,
        socket: ?*Socket = null,
    };

    fn reconnectCallback(ctx_ptr: ?*anyopaque) ?*Socket {
        const ctx: *ReconnectContext = @ptrCast(@alignCast(ctx_ptr.?));
        // Create a fresh socket and connect to the same host:port
        const socket = ctx.allocator.create(Socket) catch return null;
        socket.* = Socket.create() catch {
            ctx.allocator.destroy(socket);
            return null;
        };
        socket.connectHost(ctx.host, ctx.port) catch {
            socket.close();
            ctx.allocator.destroy(socket);
            return null;
        };
        socket.setNoDelay(true) catch {};
        ctx.socket = socket;
        return socket;
    }

    fn executeTlsHttp(self: *Self, socket: *Socket, host: []const u8, port: u16, request_data: []const u8, verify_ssl: bool) !Response {
        dbg.entry("CLIENT", "executeTlsHttp");
        dbg.log("CLIENT", "host={s} port={d} verify_ssl={s}", .{ host, port, if (verify_ssl) "true" else "false" });
        defer dbg.exit("CLIENT", "executeTlsHttp");
        const tls_cfg = if (verify_ssl) TlsConfig.init(self.allocator) else TlsConfig.insecure(self.allocator);

        // Set up reconnect context for TLS version fallback.
        // When TLS 1.3 fails and the server closes the connection,
        // we need a fresh TCP socket for the TLS 1.2 retry.
        var reconnect_ctx = ReconnectContext{
            .allocator = self.allocator,
            .host = host,
            .port = port,
            .socket = null,
        };
        // Ensure reconnect socket is cleaned up on any error
        errdefer if (reconnect_ctx.socket) |s| {
            s.close();
            self.allocator.destroy(s);
        };

        var session = TlsSession.init(tls_cfg);
        defer session.deinit();
        session.attachSocket(socket);
        session.reconnect_fn = reconnectCallback;
        session.reconnect_ctx = &reconnect_ctx;
        try session.handshake(host);

        // Use encrypted write/read (TLS record layer)
        try session.writeAll(request_data);
        try session.flush();

        var buf: [16 * 1024]u8 = undefined;
        var total_read: usize = 0;
        var parser = Parser.initResponse(self.allocator);
        defer parser.deinit();

        while (!parser.isComplete()) {
            const n = try session.read(&buf);
            if (n == 0) break;
            total_read += n;
            if (total_read > self.config.max_response_size) return error.ResponseTooLarge;
            _ = try parser.feed(buf[0..n]);
        }

        parser.finishEof();
        if (!parser.isComplete()) return error.InvalidResponse;

        // Clean up reconnect socket if it was allocated.
        // The caller's `defer socket.close()` handles the original socket.
        // session.deinit() does not close the socket, so we must clean up
        // any heap-allocated reconnect socket here.
        if (reconnect_ctx.socket) |s| {
            s.close();
            self.allocator.destroy(s);
        }

        return self.responseFromParser(&parser);
    }

    fn readResponseFromReadFn(self: *Self, reader: anytype, readFn: *const fn (@TypeOf(reader), []u8) anyerror!usize, expect_body: bool) !Response {
        var parser = Parser.initResponse(self.allocator);
        defer parser.deinit();
        parser.expect_body = expect_body;

        var buf: [16 * 1024]u8 = undefined;
        var total_read: usize = 0;
        while (!parser.isComplete()) {
            const n = try readFn(reader, &buf);
            if (n == 0) break;
            total_read += n;
            if (total_read > self.config.max_response_size) return error.ResponseTooLarge;
            _ = try parser.feed(buf[0..n]);
        }

        parser.finishEof();

        if (!parser.isComplete()) return error.InvalidResponse;
        return self.responseFromParser(&parser);
    }

    fn readResponseFromTcp(self: *Self, socket: *Socket, expect_body: bool) !Response {
        dbg.entry("CLIENT", "readResponseFromTcp");
        defer dbg.exit("CLIENT", "readResponseFromTcp");
        return self.readResponseFromReadFn(socket, Socket.recv, expect_body);
    }

    fn readResponseFromTls(self: *Self, session: *TlsSession, expect_body: bool) !Response {
        return self.readResponseFromReadFn(session, TlsSession.read, expect_body);
    }

    fn readResponseFromIo(self: *Self, r: *std.Io.Reader) !Response {
        var parser = Parser.initResponse(self.allocator);
        defer parser.deinit();

        var total_read: usize = 0;
        while (!parser.isComplete()) {
            const buffered = r.buffered();
            if (buffered.len == 0) {
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            }
            total_read += buffered.len;
            if (total_read > self.config.max_response_size) return error.ResponseTooLarge;
            const consumed = try parser.feed(buffered);
            r.toss(consumed);
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
            const raw_body = parser.getBody();
            if (res.headers.get(HeaderName.CONTENT_ENCODING)) |encoding_str| {
                if (@import("../util/compression.zig").ContentEncoding.fromString(encoding_str)) |enc| {
                    if (enc != .identity) {
                        const decompressed = @import("../util/compression.zig").decompress(parser.allocator, enc, raw_body) catch |err| {
                            return err;
                        };
                        res.body = decompressed;
                        res.body_owned = true;
                        return res;
                    }
                }
            }
            res.body = try parser.allocator.dupe(u8, raw_body);
            res.body_owned = true;
        }

        return res;
    }

    fn resolveRedirectUrl(self: *Self, base: Uri, location: []const u8) ![]u8 {
        // Absolute URL.
        if (mem.indexOf(u8, location, "://") != null) {
            return self.allocator.dupe(u8, location);
        }

        // Protocol-relative URL: //httpbun.com/path
        if (location.len > 1 and location[0] == '/' and location[1] == '/') {
            const scheme = base.scheme orelse "http";
            return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ scheme, location });
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
        dbg.entry("CLIENT", "attachCookies");
        defer dbg.exit("CLIENT", "attachCookies");
        if (self.cookies.count() == 0) return;

        const req_host = req.uri.host orelse return;

        var list = std.ArrayList(u8).empty;
        defer list.deinit(self.allocator);
        const writer = list_writer.init(self.allocator, &list);

        var it = self.cookies.iterator();
        var first = true;
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            // Cookie keys are stored as "domain|name" for domain-aware storage.
            // If there's no '|' separator, it's a legacy cookie that matches all domains.
            if (mem.lastIndexOfScalar(u8, name, '|')) |pipe| {
                const cookie_domain = name[0..pipe];
                const cookie_name = name[pipe + 1 ..];
                // Only send cookies whose domain matches the request host
                if (!domainMatches(req_host, cookie_domain)) continue;
                if (!first) try writer.writeAll("; ");
                first = false;
                try writer.print("{s}={s}", .{ cookie_name, value });
            } else {
                // Legacy cookie without domain - send to all hosts
                if (!first) try writer.writeAll("; ");
                first = false;
                try writer.print("{s}={s}", .{ name, value });
            }
        }

        if (list.items.len > 0) {
            try req.headers.set(HeaderName.COOKIE, list.items);
        }
    }

    /// Returns true if `host` matches `cookie_domain`.
    /// A cookie with domain ".httpbun.com" matches "www.httpbun.com" and "httpbun.com".
    fn domainMatches(host: []const u8, cookie_domain: []const u8) bool {
        // Exact match
        if (std.mem.eql(u8, host, cookie_domain)) return true;
        // Subdomain match: host must end with "." + cookie_domain
        if (cookie_domain.len > 0 and cookie_domain[0] == '.') {
            return std.mem.endsWith(u8, host, cookie_domain);
        }
        // Implicit dot: "httpbun.com" matches "www.httpbun.com"
        if (host.len > cookie_domain.len + 1) {
            const suffix = host[host.len - cookie_domain.len ..];
            if (std.mem.eql(u8, suffix, cookie_domain)) {
                return host[host.len - cookie_domain.len - 1] == '.';
            }
        }
        return false;
    }

    fn storeCookies(self: *Self, res: *const Response, request_host: []const u8) !void {
        dbg.entry("CLIENT", "storeCookies");
        defer dbg.exit("CLIENT", "storeCookies");
        const values = try res.headers.getAll(HeaderName.SET_COOKIE, self.allocator);
        defer self.allocator.free(values);

        for (values) |set_cookie| {
            const parsed = common.parseSetCookie(set_cookie) orelse continue;
            // Use the cookie's domain if present, otherwise fall back to the request host
            const domain = parsed.domain orelse request_host;
            // Store as "domain|name" key
            const key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ domain, parsed.name });
            errdefer self.allocator.free(key);
            const owned_value = try self.allocator.dupe(u8, parsed.value);
            errdefer self.allocator.free(owned_value);

            if (self.cookies.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            }
            try self.cookies.put(self.allocator, key, owned_value);
        }
    }

    /// Adds or replaces a cookie in the in-memory client cookie jar.
    /// The cookie is stored with domain association using "domain|name" format.
    pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !void {
        // If name already contains a domain prefix, use it as-is
        const key = if (mem.lastIndexOfScalar(u8, name, '|') != null)
            name
        else
            name; // Legacy: no domain, matches all hosts

        if (self.cookies.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }

        const owned_name = try self.allocator.dupe(u8, key);
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
    pub fn options(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.request(.OPTIONS, url, reqOpts);
    }

    /// Alias for options() with short method naming.
    pub fn opts(self: *Self, url: []const u8, reqOpts: RequestOptions) !Response {
        return self.options(url, reqOpts);
    }

    /// GET request that parses the JSON response into type T.
    /// Returns both the response and parsed value. Caller deinit's both.
    pub fn getJson(self: *Self, comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
        const response = try self.get(url, .{ .headers = &.{.{ "Accept", "application/json" }} });
        const value = try response.jsonBorrowed(T, parse_opts);
        return .{ .response = response, .value = value };
    }

    /// GET request with zero-copy JSON parse. Returns both the response and
    /// parsed value. The response must outlive the parsed value.
    pub fn getJsonBorrowed(self: *Self, comptime T: type, url: []const u8) !JsonBorrowedResult(T) {
        const response = try self.get(url, .{ .headers = &.{.{ "Accept", "application/json" }} });
        const value = try response.jsonBorrowed(T, .{});
        return .{ .response = response, .value = value };
    }

    /// POST JSON body and parse the response as type T.
    /// Returns both the response and parsed value. Caller deinit's both.
    pub fn postJsonAndParse(self: *Self, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
        const response = try self.post(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, parse_opts);
        return .{ .response = response, .value = value };
    }

    /// POST JSON body with zero-copy parse. Caller must keep response alive.
    pub fn postJsonBorrowed(self: *Self, comptime T: type, url: []const u8, body: []const u8) !JsonBorrowedResult(T) {
        const response = try self.post(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, .{});
        return .{ .response = response, .value = value };
    }

    /// PUT JSON body and parse the response as type T.
    /// Returns both the response and parsed value. Caller deinit's both.
    pub fn putJson(self: *Self, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
        const response = try self.put(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, parse_opts);
        return .{ .response = response, .value = value };
    }

    /// PUT JSON body with zero-copy parse.
    pub fn putJsonBorrowed(self: *Self, comptime T: type, url: []const u8, body: []const u8) !JsonBorrowedResult(T) {
        const response = try self.put(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, .{});
        return .{ .response = response, .value = value };
    }

    /// PATCH JSON body and parse the response as type T.
    /// Returns both the response and parsed value. Caller deinit's both.
    pub fn patchJson(self: *Self, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
        const response = try self.patch(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, parse_opts);
        return .{ .response = response, .value = value };
    }

    /// PATCH JSON body with zero-copy parse.
    pub fn patchJsonBorrowed(self: *Self, comptime T: type, url: []const u8, body: []const u8) !JsonBorrowedResult(T) {
        const response = try self.patch(url, .{ .json = body });
        const value = try response.jsonBorrowed(T, .{});
        return .{ .response = response, .value = value };
    }

    /// DELETE request that parses the JSON response as type T.
    /// Returns both the response and parsed value. Caller deinit's both.
    pub fn deleteJson(self: *Self, comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
        const response = try self.delete(url, .{ .headers = &.{.{ "Accept", "application/json" }} });
        const value = try response.jsonBorrowed(T, parse_opts);
        return .{ .response = response, .value = value };
    }

    /// DELETE request with zero-copy JSON parse.
    pub fn deleteJsonBorrowed(self: *Self, comptime T: type, url: []const u8) !JsonBorrowedResult(T) {
        const response = try self.delete(url, .{ .headers = &.{.{ "Accept", "application/json" }} });
        const value = try response.jsonBorrowed(T, .{});
        return .{ .response = response, .value = value };
    }
};

/// Result of a zero-copy JSON parse. Holds both the response (which owns the
/// body buffer) and the parsed value (which borrows string slices from it).
/// The caller must keep `response` alive while using `value`, then deinit both.
pub fn JsonBorrowedResult(comptime T: type) type {
    return struct {
        response: Response,
        value: T,
    };
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
        try self.session.flush();
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

/// Sends a QUIC RESET_STREAM frame to cancel a stream.
fn sendHttp3ResetStream(
    transport: anytype,
    session: *Http3QuicSession,
    stream_id: u64,
    error_code: u64,
    final_size: u64,
    allocator: Allocator,
) !void {
    var frame_buf: [64]u8 = undefined;
    const frame = quic.ResetStreamFrame{
        .stream_id = stream_id,
        .error_code = error_code,
        .final_size = final_size,
    };
    const frame_len = try frame.encode(&frame_buf);

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);

    try appendHttp3PacketHeader(&packet, allocator, session);
    try packet.appendSlice(allocator, frame_buf[0..frame_len]);

    try transport.sendDatagram(packet.items);
}

/// Sends a QUIC STOP_SENDING frame to tell the peer to stop sending on a stream.
fn sendHttp3StopSending(
    transport: anytype,
    session: *Http3QuicSession,
    stream_id: u64,
    error_code: u64,
    allocator: Allocator,
) !void {
    var frame_buf: [64]u8 = undefined;
    const frame = quic.StopSendingFrame{
        .stream_id = stream_id,
        .error_code = error_code,
    };
    const frame_len = try frame.encode(&frame_buf);

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);

    try appendHttp3PacketHeader(&packet, allocator, session);
    try packet.appendSlice(allocator, frame_buf[0..frame_len]);

    try transport.sendDatagram(packet.items);
}

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

fn toConnectionSettings(settings: types.Http2Settings, allow_push: bool) http.Http2Connection.Http2ConnectionSettings {
    return .{
        .header_table_size = settings.header_table_size,
        .enable_push = settings.enable_push and allow_push,
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

fn buildPseudoHeaders(
    allocator: Allocator,
    req: *Request,
    header_entries: anytype,
    owned_header_names: anytype,
    path_buf: *?[]u8,
    authority_buf: *?[]u8,
) !void {
    const path = if (req.uri.query) |q| blk: {
        path_buf.* = try std.fmt.allocPrint(allocator, "{s}?{s}", .{ req.uri.path, q });
        break :blk path_buf.*.?;
    } else req.uri.path;

    const authority = try buildAuthority(allocator, req, authority_buf);

    const method_value = if (req.method == .CUSTOM)
        (req.custom_method orelse "CUSTOM")
    else
        req.method.toString();

    try header_entries.append(allocator, .{ .name = ":method", .value = method_value });
    try header_entries.append(allocator, .{ .name = ":path", .value = path });
    try header_entries.append(allocator, .{ .name = ":scheme", .value = if (req.uri.isTls()) "https" else "http" });
    try header_entries.append(allocator, .{ .name = ":authority", .value = authority });

    for (req.headers.entries.items) |entry| {
        if (common.isConnectionSpecificHeader(entry.name) or std.ascii.eqlIgnoreCase(entry.name, HeaderName.HOST)) {
            continue;
        }
        if (entry.name.len > 0 and entry.name[0] == ':') continue;

        const lowered_name = try common.dupLowerAscii(allocator, entry.name);
        try owned_header_names.append(allocator, lowered_name);
        try header_entries.append(allocator, .{ .name = lowered_name, .value = entry.value });
    }
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
        .base_url = "http://httpbun.com",
        .user_agent = "TestClient/1.0",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("http://httpbun.com", client.config.base_url.?);
}

test "Client initForBaseUrl helper" {
    const allocator = std.testing.allocator;
    var client = Client.initForBaseUrl(allocator, "http://httpbun.com");
    defer client.deinit();

    try std.testing.expectEqualStrings("http://httpbun.com", client.config.base_url.?);
}

test "Client initialization defaults" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    try std.testing.expect(client.config.base_url == null);
    try std.testing.expect(client.config.keep_alive);
    try std.testing.expect(client.config.follow_redirects);
    try std.testing.expect(client.config.verify_ssl);
    try std.testing.expectEqual(@as(u32, 20), client.config.pool_max_connections);
    try std.testing.expectEqual(@as(u32, 5), client.config.pool_max_per_host);
}

test "ClientConfig builder helpers" {
    const default_headers = [_][2][]const u8{
        .{ "Accept", "application/json" },
    };

    const cfg = ClientConfig.defaults()
        .withBaseUrl("http://httpbun.com")
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
        .withPoolLimits(64, 16)
        .withProxy(.{ .host = "127.0.0.1", .port = 8080 });

    try std.testing.expectEqualStrings("http://httpbun.com", cfg.base_url.?);
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
    try std.testing.expect(cfg.proxy != null);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.proxy.?.host);
    try std.testing.expectEqual(@as(u16, 8080), cfg.proxy.?.port);
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

test "Client stores Set-Cookie headers" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    var response = Response.init(allocator, 200);
    defer response.deinit();

    try response.headers.append("Set-Cookie", "session=abc123; Path=/; HttpOnly");
    try response.headers.append("Set-Cookie", "theme=dark; Path=/");

    try client.storeCookies(&response, "httpbun.com");

    try std.testing.expectEqualStrings("abc123", client.cookies.get("httpbun.com|session").?);
    try std.testing.expectEqualStrings("dark", client.cookies.get("httpbun.com|theme").?);
}

test "Client attaches Cookie header from jar" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    try client.setCookie("session", "abc123");
    try client.setCookie("theme", "dark");

    var request = try Request.init(allocator, .GET, "http://httpbun.com/");
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
    try std.testing.expectEqual(@as(usize, 0), client.hostPoolConnectionCount("httpbun.com", 443));
}

test "Client retry classifier avoids TLS/protocol retries" {
    try std.testing.expect(!Client.isRetryableRequestError(error.TlsConnectionTruncated));
    try std.testing.expect(!Client.isRetryableRequestError(error.InvalidResponse));
    try std.testing.expect(!Client.isRetryableRequestError(error.ProtocolError));
    try std.testing.expect(Client.isRetryableRequestError(error.ConnectionReset));
}

test "Client proxy request formatting" {
    const allocator = std.testing.allocator;
    var client = Client.initWithConfig(allocator, .{});
    defer client.deinit();

    var req = try Request.init(allocator, .GET, "http://httpbun.com/api/v1/users?active=true");
    defer req.deinit();
    try req.headers.set("Accept", "application/json");

    const formatted = try client.formatProxyRequest(&req, .{
        .host = "127.0.0.1",
        .port = 8080,
        .username = "user",
        .password = "pass",
    });
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "GET http://httpbun.com:80/api/v1/users?active=true HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Accept: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Proxy-Authorization: Basic dXNlcjpwYXNz\r\n") != null);
}

test "Client multipart options and MIME resolution" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator);
    defer client.deinit();

    const fields = [_]MultipartField{
        .{ .name = "username", .value = "bob" },
    };
    const files = [_]MultipartFile{
        .{ .name = "doc", .filename = "notes.html", .data = "some content", .content_type = null },
        .{ .name = "custom", .filename = "data.bin", .data = "binary data", .content_type = "application/x-custom" },
    };

    var req = try Request.init(allocator, .POST, "http://localhost/");
    defer req.deinit();

    const reqOpts = RequestOptions.defaults()
        .withMultipartFields(&fields)
        .withMultipartFiles(&files);

    if (reqOpts.multipart_fields != null or reqOpts.multipart_files != null) {
        const boundary = reqOpts.multipart_boundary orelse "----httpxBoundary1234567890";
        var builder = @import("../util/multipart.zig").MultipartBuilder.init(allocator, boundary);
        defer builder.deinit();

        if (reqOpts.multipart_fields) |flds| {
            for (flds) |field| {
                try builder.addField(field.name, field.value);
            }
        }

        if (reqOpts.multipart_files) |fls| {
            for (fls) |file| {
                const resolved_mime = file.content_type orelse common.mimeTypeFromPathOr(file.filename, "application/octet-stream");
                try builder.addFile(file.name, file.filename, resolved_mime, file.data);
            }
        }

        const body = try builder.build();
        defer allocator.free(body);
        try req.setBody(body);

        const ct = try builder.contentType();
        defer allocator.free(ct);
        try req.headers.set(HeaderName.CONTENT_TYPE, ct);
    }

    try std.testing.expect(req.body != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body.?, "text/html; charset=utf-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body.?, "application/x-custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body.?, "name=\"username\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body.?, "bob") != null);

    const ct = req.headers.get("Content-Type").?;
    try std.testing.expect(std.mem.startsWith(u8, ct, "multipart/form-data; boundary=----httpxBoundary1234567890"));
}

test "RequestOptions per-request overrides" {
    const proxy = types.Proxy{
        .kind = .http,
        .host = "127.0.0.1",
        .port = 8888,
        .username = null,
        .password = null,
    };

    const opts = RequestOptions.defaults()
        .withProxy(proxy)
        .withSslVerification(false)
        .withKeepAlive(false)
        .withUnixSocket("/tmp/test.sock");

    try std.testing.expect(opts.proxy != null);
    try std.testing.expectEqualStrings("127.0.0.1", opts.proxy.?.host);
    try std.testing.expectEqual(@as(u16, 8888), opts.proxy.?.port);
    try std.testing.expectEqual(false, opts.verify_ssl.?);
    try std.testing.expectEqual(false, opts.keep_alive.?);
    try std.testing.expectEqualStrings("/tmp/test.sock", opts.unix_socket_path.?);
}

test "RequestOptions explicit timeout resolution" {
    const allocator = std.testing.allocator;
    var client = Client.initWithConfig(allocator, .{
        .timeouts = .{
            .connect_ms = 5000,
            .read_ms = 10000,
            .write_ms = 15000,
        },
    });
    defer client.deinit();

    // Default fallback
    const t_def = client.resolveRequestTimeouts(.{});
    try std.testing.expectEqual(@as(u64, 5000), t_def.connect_ms);
    try std.testing.expectEqual(@as(u64, 10000), t_def.read_ms);
    try std.testing.expectEqual(@as(u64, 15000), t_def.write_ms);

    // Uniform timeout_ms override
    const t_uni = client.resolveRequestTimeouts(RequestOptions.defaults().withTimeoutMs(2000));
    try std.testing.expectEqual(@as(u64, 2000), t_uni.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), t_uni.read_ms);
    try std.testing.expectEqual(@as(u64, 2000), t_uni.write_ms);

    // Explicit per-phase timeout overrides
    const t_exp = client.resolveRequestTimeouts(
        RequestOptions.defaults()
            .withConnectTimeoutMs(100)
            .withReadTimeoutMs(200)
            .withWriteTimeoutMs(300),
    );
    try std.testing.expectEqual(@as(u64, 100), t_exp.connect_ms);
    try std.testing.expectEqual(@as(u64, 200), t_exp.read_ms);
    try std.testing.expectEqual(@as(u64, 300), t_exp.write_ms);

    // Explicit timeouts struct override
    const t_struct = client.resolveRequestTimeouts(
        RequestOptions.defaults().withTimeouts(.{
            .connect_ms = 111,
            .read_ms = 222,
            .write_ms = 333,
        }),
    );
    try std.testing.expectEqual(@as(u64, 111), t_struct.connect_ms);
    try std.testing.expectEqual(@as(u64, 222), t_struct.read_ms);
    try std.testing.expectEqual(@as(u64, 333), t_struct.write_ms);
}
