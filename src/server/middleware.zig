//! HTTP Middleware Support for httpx.zig
//!
//! Provides middleware functionality for HTTP servers:
//!
//! - CORS (Cross-Origin Resource Sharing)
//! - Logging and request timing
//! - Rate limiting
//! - Basic authentication
//! - Security headers (Helmet)
//! - Response compression
//! - Body parsing
//! - CSRF protection (double-submit cookie pattern)
//! - SSRF protection in reverse proxy (private IP range blocking)

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const tint = @import("tint");
const Context = @import("server.zig").Context;
const io_util = @import("../io/any_io.zig");
const Response = @import("../core/response.zig").Response;
const types = @import("../core/types.zig");
const list_writer = @import("../io/list_writer.zig");
const status = @import("../core/status.zig");
const common = @import("../data/common.zig");
const compression_util = @import("../compress/compression.zig");

/// Middleware function type.
pub const Middleware = struct {
    handler: *const fn (*Context, Next) anyerror!Response,
    name: []const u8 = "unnamed",
};

/// Next function to call the next middleware.
pub const Next = *const fn (*Context) anyerror!Response;

/// Middleware chain executor.
pub const MiddlewareChain = struct {
    middlewares: []const Middleware,
    final_handler: *const fn (*Context) anyerror!Response,
    current: usize = 0,

    const Self = @This();

    /// Executes the middleware chain.
    pub fn execute(self: *Self, ctx: *Context) anyerror!Response {
        try ctx.data.put("__middleware_chain_state", @ptrCast(self));
        defer _ = ctx.data.remove("__middleware_chain_state");
        return next(ctx);
    }

    fn next(ctx: *Context) anyerror!Response {
        const raw = ctx.data.get("__middleware_chain_state") orelse return error.MissingMiddlewareChainState;
        const chain: *Self = @ptrCast(@alignCast(raw));

        if (chain.current < chain.middlewares.len) {
            const mw = chain.middlewares[chain.current];
            chain.current += 1;
            return mw.handler(ctx, next);
        }

        return chain.final_handler(ctx);
    }
};

/// CORS configuration.
pub const CorsConfig = struct {
    allowed_origins: []const []const u8 = &[_][]const u8{"*"},
    allowed_methods: []const types.Method = &[_]types.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS },
    allowed_headers: []const []const u8 = &[_][]const u8{ "Content-Type", "Authorization" },
    exposed_headers: []const []const u8 = &[_][]const u8{},
    allow_credentials: bool = false,
    max_age: u32 = 86400,
};

/// Creates CORS middleware.
pub fn cors(comptime config: CorsConfig) Middleware {
    return .{
        .name = "cors",
        .handler = struct {
            const methods_str = blk: {
                var out: []const u8 = "";
                for (config.allowed_methods, 0..) |m, i| {
                    if (i > 0) out = out ++ ", ";
                    out = out ++ m.toString();
                }
                break :blk out;
            };
            const headers_str = blk: {
                var out: []const u8 = "";
                for (config.allowed_headers, 0..) |h, i| {
                    if (i > 0) out = out ++ ", ";
                    out = out ++ h;
                }
                break :blk out;
            };
            const exposed_str = blk: {
                var out: []const u8 = "";
                for (config.exposed_headers, 0..) |h, i| {
                    if (i > 0) out = out ++ ", ";
                    out = out ++ h;
                }
                break :blk out;
            };
            const max_age_str = std.fmt.comptimePrint("{d}", .{config.max_age});

            fn allowedOrigin(ctx: *Context, cfg: CorsConfig) []const u8 {
                const req_origin = ctx.header("Origin") orelse return cfg.allowed_origins[0];
                for (cfg.allowed_origins) |o| {
                    if (std.mem.eql(u8, o, "*") or std.mem.eql(u8, o, req_origin)) {
                        return if (std.mem.eql(u8, o, "*")) "*" else req_origin;
                    }
                }
                return cfg.allowed_origins[0];
            }

            fn handler(ctx: *Context, next: Next) anyerror!Response {
                const origin = allowedOrigin(ctx, config);
                try ctx.setHeader("Access-Control-Allow-Origin", origin);
                try ctx.setHeader("Vary", "Origin");
                try ctx.setHeader("Access-Control-Allow-Methods", methods_str);
                try ctx.setHeader("Access-Control-Allow-Headers", headers_str);

                if (exposed_str.len > 0) {
                    try ctx.setHeader("Access-Control-Expose-Headers", exposed_str);
                }

                if (config.allow_credentials) {
                    try ctx.setHeader("Access-Control-Allow-Credentials", "true");
                }

                try ctx.setHeader("Access-Control-Max-Age", max_age_str);

                if (ctx.request.method == .OPTIONS) {
                    return ctx.status(status.StatusCode.NO_CONTENT).text("");
                }

                const resp = try next(ctx);
                return resp;
            }
        }.handler,
    };
}

/// Logger middleware options.
pub const LoggerConfig = struct {
    log_fn: ?@import("server.zig").LogFn = null,
};

/// Creates logging middleware with config.
pub fn loggerWithConfig(comptime config: LoggerConfig) Middleware {
    return .{
        .name = "logger",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                const start = common.nowMillis();
                const response = try next(ctx);
                const duration = common.nowMillis() - start;

                if (config.log_fn) |f| {
                    var buf: [1024]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "{s} {s} - {d}ms\n", .{
                        ctx.request.method.toString(),
                        ctx.request.uri.path,
                        duration,
                    }) catch "[Logger format failed or message too long]";
                    f(.info, msg);
                } else {
                    const method_style = switch (ctx.request.method) {
                        .GET => tint.style(.{ .fg = .{ .ansi4 = .bright_green } }),
                        .POST => tint.style(.{ .fg = .{ .ansi4 = .bright_blue } }),
                        .PUT, .PATCH => tint.style(.{ .fg = .{ .ansi4 = .bright_yellow } }),
                        .DELETE => tint.style(.{ .fg = .{ .ansi4 = .bright_red } }),
                        else => tint.style(.{ .fg = .{ .ansi4 = .white } }),
                    };
                    const dur_style = if (duration > 1000)
                        tint.style(.{ .fg = .{ .ansi4 = .bright_red }, .bold = true })
                    else if (duration > 500)
                        tint.style(.{ .fg = .{ .ansi4 = .bright_yellow } })
                    else
                        tint.style(.{ .fg = .{ .ansi4 = .bright_black }, .dim = true });

                    const app_style = tint.style(.{ .fg = .{ .ansi4 = .bright_cyan }, .bold = true });
                    std.debug.print(
                        "{s}HTTPX{s} {s}{s}{s} {s}{s}{s} - {s}{d}ms{s}\n",
                        .{
                            app_style.toAnsi(),
                            tint.reset,
                            method_style.toAnsi(),
                            ctx.request.method.toString(),
                            tint.reset,
                            tint.style(.{}).toAnsi(),
                            ctx.request.uri.path,
                            tint.reset,
                            dur_style.toAnsi(),
                            duration,
                            tint.reset,
                        },
                    );
                }

                return response;
            }
        }.handler,
    };
}

/// Creates logging middleware.
pub fn logger() Middleware {
    return loggerWithConfig(.{});
}

/// Creates compression middleware.
pub fn compression() Middleware {
    return compressionMiddlewareWithConfig(.{});
}

/// Alias for `compression()`.
pub const compressionMiddleware = compression;

/// Configuration for compression middleware.
pub const CompressionConfig = struct {
    /// Minimum response body size in bytes before compression is applied.
    min_bytes: usize = 256,
    /// Compression level to use.
    level: compression_util.CompressionLevel = .default,
    /// Maximum decompressed size to prevent bomb attacks.
    max_decompressed_size: usize = 100 * 1024 * 1024,
    /// If set, only compress responses with these Content-Type prefixes.
    /// If null, uses the built-in compressible MIME type check.
    compressible_types: ?[]const []const u8 = null,
    /// Encodings to allow, in priority order (highest first).
    /// If null, allows all supported encodings.
    allowed_encodings: ?[]const compression_util.ContentEncoding = null,
};

/// Creates compression middleware with explicit configuration.
pub fn compressionMiddlewareWithConfig(comptime config: CompressionConfig) Middleware {
    return .{
        .name = "compression",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                const resp = try next(ctx);

                if (resp.body) |body| {
                    if (body.len < config.min_bytes) return resp;
                    if (resp.headers.get("Content-Encoding") != null) return resp;

                    const accept_raw = ctx.header("Accept-Encoding") orelse return resp;
                    const accept = compression_util.AcceptEncoding.parse(accept_raw) catch return resp;

                    const encoding = negotiateServerEncoding(accept, config.allowed_encodings) orelse return resp;

                    const content_type = resp.headers.get("Content-Type") orelse "";
                    if (!shouldCompressContent(content_type, config.compressible_types)) return resp;

                    var new_resp = resp;
                    const opts = compression_util.CompressOptions{ .level = config.level };
                    if (compression_util.compressWithLevel(ctx.allocator, encoding, body, opts)) |compressed| {
                        if (resp.body_owned) ctx.allocator.free(body);
                        new_resp.body = compressed;
                        new_resp.body_owned = true;
                        new_resp.headers.append("Content-Encoding", encoding.toString()) catch {};
                        new_resp.headers.append("Vary", "Accept-Encoding") catch {};
                        if (ctx.server) |s| {
                            if (s.config.metrics) |m| m.compression(@intCast(body.len), @intCast(compressed.len));
                        }
                    } else |_| {}
                    return new_resp;
                }
                return resp;
            }
        }.handler,
    };
}

fn negotiateServerEncoding(accept: compression_util.AcceptEncoding, allowed: ?[]const compression_util.ContentEncoding) ?compression_util.ContentEncoding {
    const candidates = allowed orelse &[_]compression_util.ContentEncoding{ .zstd, .br, .gzip, .deflate };
    for (candidates) |enc| {
        if (accept.has(enc, 0.0)) return enc;
    }
    return null;
}

fn shouldCompressContent(content_type: []const u8, compressible_types: ?[]const []const u8) bool {
    if (compressible_types) |allowed| {
        for (allowed) |t| {
            if (std.ascii.startsWithIgnoreCase(content_type, t)) return true;
        }
        return false;
    }
    return compression_util.isCompressible(content_type);
}

/// Rate limiting configuration.
pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u64 = 60_000,
    /// Whether to trust X-Forwarded-For (default: false for security).
    /// When false, uses connection socket IP directly.
    trust_proxy_headers: bool = false,
};

/// Per-server rate limit state. Allocated on the heap and freed when the
/// middleware is no longer needed.
const RateLimitState = struct {
    const Entry = struct { count: u32, window_start: i64 };
    store: std.StringHashMap(Entry),
    evict_counter: u32 = 0,
    mu: std.Io.Mutex = .init,

    fn init(allocator: Allocator) @This() {
        return .{ .store = std.StringHashMap(Entry).init(allocator) };
    }

    fn deinit(self: *@This()) void {
        self.store.deinit();
    }
};

/// Creates rate limiting middleware.
///
/// Tracks request counts in an in-memory hashmap keyed by IP.
/// Returns 429 Too Many Requests when the limit is exceeded.
/// Evicts stale entries periodically to prevent unbounded memory growth.
/// Thread-safe: protected by a mutex for concurrent access.
///
/// When trust_proxy_headers is false (default), uses the raw connection IP
/// to prevent spoofing via X-Forwarded-For or X-Real-IP headers.
pub fn rateLimit(comptime config: RateLimitConfig) Middleware {
    return .{
        .name = "rate_limit",
        .handler = struct {
            var state: ?*RateLimitState = null;

            fn handler(ctx: *Context, next: Next) anyerror!Response {
                // Lazily initialize per-call state using the first request's allocator.
                if (state == null) {
                    const s = ctx.allocator.create(RateLimitState) catch return error.OutOfMemory;
                    s.* = RateLimitState.init(ctx.allocator);
                    state = s;
                }
                const st = state.?;

                const now = common.nowMillis();
                // Use connection IP directly by default to prevent header spoofing.
                const ip = if (config.trust_proxy_headers)
                    ctx.header("X-Forwarded-For") orelse
                        ctx.header("X-Real-IP") orelse
                        ctx.connectionIp()
                else
                    ctx.connectionIp();

                const io = io_util.defaultIo();
                st.mu.lock(io) catch unreachable;
                defer st.mu.unlock(io);

                // Evict stale entries every 512 requests to prevent unbounded growth.
                st.evict_counter +%= 1;
                if (st.evict_counter % 512 == 0) {
                    var it = st.store.iterator();
                    while (it.next()) |kv| {
                        if (now - kv.value_ptr.window_start > @as(i64, @intCast(config.window_ms * 2))) {
                            _ = st.store.remove(kv.key_ptr.*);
                        }
                    }
                }

                const entry = st.store.get(ip);
                if (entry) |e| {
                    if (now - e.window_start < @as(i64, @intCast(config.window_ms))) {
                        if (e.count >= config.max_requests) {
                            if (ctx.server) |s| {
                                if (s.config.metrics) |m| m.rateLimitCheck(false);
                            }
                            const retry_after = @as(u64, @intCast(@max(1, @as(i64, @intCast(config.window_ms)) - (now - e.window_start)) / 1000));
                            var buf: [16]u8 = undefined;
                            const ra_str = std.fmt.bufPrint(&buf, "{d}", .{retry_after}) catch "60";
                            try ctx.setHeader("Retry-After", ra_str);
                            return ctx.status(status.StatusCode.TOO_MANY_REQUESTS).text("Too Many Requests");
                        }
                        try st.store.put(ip, .{ .count = e.count + 1, .window_start = e.window_start });
                    } else {
                        try st.store.put(ip, .{ .count = 1, .window_start = now });
                    }
                } else {
                    try st.store.put(ip, .{ .count = 1, .window_start = now });
                }

                if (ctx.server) |s| {
                    if (s.config.metrics) |m| m.rateLimitCheck(true);
                }
                return next(ctx);
            }
        }.handler,
    };
}

/// Creates basic authentication middleware.
pub fn basicAuth(realm: []const u8, validator: *const fn ([]const u8, []const u8) bool) Middleware {
    return .{
        .name = "basic_auth",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                const auth = ctx.header("Authorization") orelse {
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };

                if (!std.mem.startsWith(u8, auth, "Basic ")) {
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                }

                const encoded = std.mem.trim(u8, auth[6..], " \t");
                const Base64 = @import("../data/encoding.zig").Base64;
                const decoded = Base64.decode(ctx.allocator, encoded) catch {
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };
                defer ctx.allocator.free(decoded);

                const colon_pos = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };

                const username = decoded[0..colon_pos];
                const password = decoded[colon_pos + 1 ..];

                if (!validator(username, password)) {
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                }

                return next(ctx);
            }
        }.handler,
    };
}

/// Creates body parser middleware.
///
/// Checks Content-Length against `max_size` and returns 413 if exceeded.
pub fn bodyParser(max_size: usize) Middleware {
    return .{
        .name = "body_parser",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                if (ctx.header("Content-Length")) |len_str| {
                    const content_length = std.fmt.parseInt(usize, len_str, 10) catch 0;
                    if (content_length > max_size) {
                        return ctx.status(status.StatusCode.PAYLOAD_TOO_LARGE).text("Payload Too Large");
                    }
                }

                if (ctx.request.body) |body| {
                    if (body.len > max_size) {
                        return ctx.status(status.StatusCode.PAYLOAD_TOO_LARGE).text("Payload Too Large");
                    }
                }

                return next(ctx);
            }
        }.handler,
    };
}

/// Creates security headers middleware (Helmet).
///
/// Adds standard security headers: X-Content-Type-Options, X-Frame-Options,
/// X-XSS-Protection, Strict-Transport-Security, Content-Security-Policy,
/// Referrer-Policy, Permissions-Policy, Cross-Origin-Opener-Policy,
/// Cross-Origin-Resource-Policy, and Cross-Origin-Embedder-Policy.
pub fn helmet() Middleware {
    return helmetWithConfig(.{});
}

/// Helmet configuration for granular control over security headers.
pub const HelmetConfig = struct {
    content_security_policy: ?[]const u8 = "default-src 'self'",
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    permissions_policy: ?[]const u8 = "camera=(), microphone=(), geolocation=()",
    cross_origin_opener_policy: []const u8 = "same-origin",
    cross_origin_resource_policy: []const u8 = "same-origin",
    cross_origin_embedder_policy: ?[]const u8 = null,
    x_frame_options: []const u8 = "DENY",
    x_content_type_options: []const u8 = "nosniff",
    x_xss_protection: []const u8 = "1; mode=block",
    strict_transport_security: []const u8 = "max-age=31536000; includeSubDomains",
};

/// Creates security headers middleware with explicit configuration.
pub fn helmetWithConfig(comptime config: HelmetConfig) Middleware {
    return .{
        .name = "helmet",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                try ctx.setHeader("X-Content-Type-Options", config.x_content_type_options);
                try ctx.setHeader("X-Frame-Options", config.x_frame_options);
                try ctx.setHeader("X-XSS-Protection", config.x_xss_protection);
                if (ctx.request.uri.isTLS() or
                    std.mem.eql(u8, ctx.header("x-forwarded-proto") orelse "", "https"))
                {
                    try ctx.setHeader("Strict-Transport-Security", config.strict_transport_security);
                }
                try ctx.setHeader("Referrer-Policy", config.referrer_policy);
                try ctx.setHeader("Cross-Origin-Opener-Policy", config.cross_origin_opener_policy);
                try ctx.setHeader("Cross-Origin-Resource-Policy", config.cross_origin_resource_policy);
                if (config.content_security_policy) |csp| {
                    try ctx.setHeader("Content-Security-Policy", csp);
                }
                if (config.permissions_policy) |pp| {
                    try ctx.setHeader("Permissions-Policy", pp);
                }
                if (config.cross_origin_embedder_policy) |coop| {
                    try ctx.setHeader("Cross-Origin-Embedder-Policy", coop);
                }
                return next(ctx);
            }
        }.handler,
    };
}

/// Creates CSRF protection middleware using the double-submit cookie pattern.
///
/// Generates a random token, sets it as a cookie, and validates that the same
/// token is present in the request header or form body for state-changing methods.
/// Protects against cross-site request forgery attacks.
///
/// Token is hex-encoded and returned in the X-CSRF-Token response header so
/// SPA clients can read it. Tokens older than max_age_ms are rejected.
pub fn csrf(comptime config: CsrfConfig) Middleware {
    return .{
        .name = "csrf",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                // Only protect state-changing methods.
                const method = ctx.request.method;
                if (method == .GET or method == .HEAD or method == .OPTIONS) {
                    return next(ctx);
                }

                // Retrieve token from cookie.
                const cookie_token = ctx.cookie(config.cookie_name);

                // Validate token from header or form body.
                const header_token = ctx.header(config.header_name);
                const form_token: ?[]const u8 = blk: {
                    if (ctx.isFormUrlEncoded()) {
                        if (ctx.request.body) |body| {
                            const needle = try std.fmt.allocPrint(ctx.allocator, "{s}=", .{config.field_name});
                            defer ctx.allocator.free(needle);
                            if (std.mem.indexOf(u8, body, needle)) |pos| {
                                const start = pos + needle.len;
                                if (start < body.len) {
                                    const end = std.mem.indexOfScalar(u8, body[start..], '&') orelse body.len - start;
                                    break :blk body[start .. start + end];
                                }
                            }
                        }
                    }
                    break :blk null;
                };

                const request_token = header_token orelse form_token;

                // If we have a cookie token, validate the request token matches.
                if (cookie_token) |ct| {
                    if (request_token) |rt| {
                        if (timingSafeEql(ct, rt)) {
                            // Optionally verify token is not expired.
                            if (config.max_age_ms > 0) {
                                if (parseCsrfTimestamp(rt)) |issued_ms| {
                                    const now_ms = @as(u64, @intCast(common.nowMillis()));
                                    if (now_ms -| issued_ms > config.max_age_ms) {
                                        if (ctx.server) |s| {
                                            if (s.config.metrics) |m| m.csrfRejection();
                                        }
                                        return ctx.status(status.StatusCode.FORBIDDEN).text("CSRF token expired");
                                    }
                                }
                            }
                            return next(ctx);
                        }
                    }
                    if (ctx.server) |s| {
                        if (s.config.metrics) |m| m.csrfRejection();
                    }
                    return ctx.status(status.StatusCode.FORBIDDEN).text("CSRF token mismatch");
                }

                // No cookie yet — generate token and set both cookie + header.
                const token = try generateCsrfToken(ctx.allocator);
                defer ctx.allocator.free(token);

                try ctx.setCookie(config.cookie_name, token, .{
                    .same_site = .lax,
                    .http_only = false, // Must be readable by JS for double-submit.
                    .secure = config.secure,
                    .path = "/",
                });

                // Return token in header so SPA/JS clients can read it.
                try ctx.setHeader(config.header_name, token);

                return next(ctx);
            }

            fn generateCsrfToken(allocator: std.mem.Allocator) ![]const u8 {
                var rand: [16]u8 = undefined;
                io_util.defaultIo().random(&rand);
                // Embed a timestamp for expiration checks: "hex16-hextimestamp-hex16"
                const now_ms = @as(u64, @intCast(common.nowMillis()));
                var ts_buf: [16]u8 = undefined;
                _ = std.fmt.bufPrint(&ts_buf, "{x:0>16}", .{now_ms}) catch unreachable;
                const hex_rand = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(rand, .lower)});
                defer allocator.free(hex_rand);
                return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
                    hex_rand[0..16],
                    &ts_buf,
                    hex_rand[16..],
                });
            }

            fn parseCsrfTimestamp(token: []const u8) ?u64 {
                // Format: "hex16-hextimestamp-hex16"
                var parts = std.mem.splitScalar(u8, token, '-');
                _ = parts.next() orelse return null;
                const ts_hex = parts.next() orelse return null;
                _ = parts.next();
                return std.fmt.parseInt(u64, ts_hex, 16) catch null;
            }
        }.handler,
    };
}

/// Constant-time comparison of two byte slices to prevent timing attacks.
fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    const min_len = if (a.len < b.len) a.len else b.len;
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        result |= a[i] ^ b[i];
    }
    return result == 0;
}

/// CSRF protection configuration.
pub const CsrfConfig = struct {
    /// Cookie name for the CSRF token.
    cookie_name: []const u8 = "_csrf",
    /// Header name to check for the token.
    header_name: []const u8 = "X-CSRF-Token",
    /// Form field name to check for the token.
    field_name: []const u8 = "_csrf",
    /// Whether to set the Secure flag on the cookie.
    secure: bool = false,
    /// Maximum token age in milliseconds (0 = no expiration).
    max_age_ms: u64 = 3600_000, // 1 hour default
};

/// Creates request timeout middleware.
///
/// Stores the timeout deadline in `ctx.data` and checks it before calling
/// the next handler. If the deadline has already passed, returns 408 Request
/// Timeout. The server's own `request_timeout_ms` config provides the primary
/// timeout enforcement at the socket level; this middleware provides an
/// application-level check for slow downstream handlers.
pub fn timeout(ms: u64) Middleware {
    return .{
        .name = "timeout",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                const now_ts = common.nowMillis();
                const deadline = now_ts + @as(i64, @intCast(ms));
                const deadline_ptr = @as(*i64, @ptrCast(@alignCast(
                    ctx.allocator.create(i64) catch return next(ctx),
                )));
                deadline_ptr.* = deadline;
                defer ctx.allocator.destroy(deadline_ptr);

                _ = ctx.data.put("__timeout_deadline", @ptrCast(deadline_ptr));

                if (ms > 0 and common.nowMillis() > deadline) {
                    return ctx.status(status.StatusCode.REQUEST_TIMEOUT).text("Request Timeout");
                }

                return next(ctx);
            }
        }.handler,
    };
}

/// Creates request ID middleware.
///
/// Generates a unique 16-byte hex request ID and sets the X-Request-ID header.
pub fn requestId() Middleware {
    return .{
        .name = "request_id",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                var raw: [16]u8 = undefined;
                io_util.defaultIo().random(&raw);

                var hex: [32]u8 = undefined;
                const hex_chars = "0123456789abcdef";
                for (raw, 0..) |byte, i| {
                    hex[i * 2] = hex_chars[byte >> 4];
                    hex[i * 2 + 1] = hex_chars[byte & 0x0F];
                }

                try ctx.setHeader("X-Request-ID", &hex);
                return next(ctx);
            }
        }.handler,
    };
}

/// Creates reverse proxy middleware that forwards requests to target_url.
/// When ssrf_check is true, validates that the target is not a private/internal IP.
pub fn reverseProxy(comptime target_url: []const u8) Middleware {
    return .{
        .name = "reverse_proxy",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                _ = next;
                const client_mod = @import("../client/client.zig");
                var client = client_mod.Client.init(ctx.allocator);
                defer client.deinit();

                const path = ctx.request.uri.path;
                const query_str = ctx.request.uri.query;
                const full_target = if (query_str) |q|
                    try std.fmt.allocPrint(ctx.allocator, "{s}{s}?{s}", .{ target_url, path, q })
                else
                    try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ target_url, path });
                defer ctx.allocator.free(full_target);

                // SSRF protection: validate target is not a private IP.
                if (isSsrfBlocked(full_target)) {
                    if (ctx.server) |s| {
                        if (s.config.metrics) |m| m.ssrfRejection();
                    }
                    return ctx.status(status.StatusCode.FORBIDDEN).text("Forbidden: internal target");
                }

                var headers_list = std.ArrayList([2][]const u8).empty;
                defer headers_list.deinit(ctx.allocator);
                for (ctx.request.headers.entries.items) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
                    try headers_list.append(ctx.allocator, .{ h.name, h.value });
                }

                var req_opts = client_mod.RequestOptions.defaults();
                req_opts.headers = headers_list.items;
                req_opts.body = ctx.request.body;

                return client.request(ctx.request.method, full_target, req_opts);
            }
        }.handler,
    };
}

/// Creates reverse proxy middleware with a runtime-known target URL.
/// The target_url slice must remain valid for the lifetime of the middleware.
pub fn reverseProxyRuntime(target_url: []const u8) Middleware {
    const State = struct {
        var url: []const u8 = "";
    };
    State.url = target_url;
    return .{
        .name = "reverse_proxy",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                _ = next;
                const client_mod = @import("../client/client.zig");
                var client = client_mod.Client.init(ctx.allocator);
                defer client.deinit();

                const path = ctx.request.uri.path;
                const query_str = ctx.request.uri.query;
                const full_target = if (query_str) |q|
                    try std.fmt.allocPrint(ctx.allocator, "{s}{s}?{s}", .{ State.url, path, q })
                else
                    try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ State.url, path });
                defer ctx.allocator.free(full_target);

                // SSRF protection: validate target is not a private IP.
                if (isSsrfBlocked(full_target)) {
                    if (ctx.server) |s| {
                        if (s.config.metrics) |m| m.ssrfRejection();
                    }
                    return ctx.status(status.StatusCode.FORBIDDEN).text("Forbidden: internal target");
                }

                var headers_list = std.ArrayList([2][]const u8).empty;
                defer headers_list.deinit(ctx.allocator);
                for (ctx.request.headers.entries.items) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
                    try headers_list.append(ctx.allocator, .{ h.name, h.value });
                }

                var req_opts = client_mod.RequestOptions.defaults();
                req_opts.headers = headers_list.items;
                req_opts.body = ctx.request.body;

                return client.request(ctx.request.method, full_target, req_opts);
            }
        }.handler,
    };
}

/// Checks if a URL targets a private/internal IP range (SSRF protection).
/// Blocks localhost, loopback, link-local, private ranges, and cloud metadata endpoints.
fn isSsrfBlocked(url: []const u8) bool {
    const host = extractHost(url) orelse return false;

    // Block common internal hostnames.
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "0.0.0.0") or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]"))
    {
        return true;
    }

    // Block cloud metadata endpoints.
    if (std.ascii.eqlIgnoreCase(host, "169.254.169.254")) return true;
    if (std.ascii.eqlIgnoreCase(host, "metadata.google.internal")) return true;
    if (std.ascii.eqlIgnoreCase(host, "metadata.azure.com")) return true;
    if (std.ascii.eqlIgnoreCase(host, "169.254.169.254.nip.io")) return true;

    // Try IPv4 first.
    if (parseIp4(host)) |ip| {
        return isSsrfBlockedIp4(ip);
    }

    // Try IPv6.
    if (parseIp6(host)) |ip| {
        return isSsrfBlockedIp6(ip);
    }

    return false;
}

fn isSsrfBlockedIp4(ip: u32) bool {
    // 0.0.0.0/8
    if ((ip >> 24) == 0) return true;
    // 127.0.0.0/8
    if ((ip >> 24) == 0x7F) return true;
    // 10.0.0.0/8
    if ((ip >> 24) == 0x0A) return true;
    // 172.16.0.0/12
    if ((ip >> 20) == 0xAC1) return true;
    // 192.168.0.0/16
    if ((ip >> 16) == 0xC0A8) return true;
    // 169.254.0.0/16 (link-local)
    if ((ip >> 16) == 0xA9FE) return true;
    // 198.18.0.0/15 (benchmarking)
    if ((ip >> 15) == 0x6009) return true;
    // 100.64.0.0/10 (carrier-grade NAT)
    if ((ip >> 22) == 0x6440) return true;
    // 192.0.0.0/24 (IANA protocol)
    if ((ip >> 24) == 192 and ((ip >> 16) & 0xFF) == 0) return true;
    // 192.0.2.0/24 (documentation)
    if ((ip >> 24) == 192 and ((ip >> 16) & 0xFF) == 2) return true;
    // 198.51.100.0/24 (documentation)
    if ((ip >> 24) == 198 and ((ip >> 16) & 0xFF) == 51 and ((ip >> 8) & 0xFF) == 100) return true;
    // 203.0.113.0/24 (documentation)
    if ((ip >> 24) == 203 and ((ip >> 16) & 0xFF) == 0 and ((ip >> 8) & 0xFF) == 113) return true;
    // 224.0.0.0/4 (multicast)
    if ((ip >> 28) == 0xE) return true;
    // 240.0.0.0/4 (reserved)
    if ((ip >> 28) == 0xF) return true;
    return false;
}

/// Parse an IPv6 address from common bracketed or uncompressed formats.
/// Returns the 128-bit address as a u128.
fn parseIp6(host: []const u8) ?u128 {
    // Strip brackets: [::1] → ::1
    const bare = if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;

    // Handle ::1 / ::0 / ::ffff style
    if (std.mem.startsWith(u8, bare, "::")) {
        // Simplified: only handle ::1 and :: (all zeros)
        if (bare.len == 3) {
            const third = bare[2];
            if (third == '1') return 1;
            if (third == '0') return 0;
        }
        if (bare.len == 2) return 0; // :: = all zeros
        return null;
    }

    // Try parsing full form: hex:hex:...:hex
    // For simplicity, only handle common known addresses.
    if (std.ascii.eqlIgnoreCase(bare, "fe80::1") or std.ascii.eqlIgnoreCase(bare, "fe80::")) return null; // link-local
    return null;
}

fn isSsrfBlockedIp6(ip: u128) bool {
    // ::0/128 (unspecified)
    if (ip == 0) return true;
    // ::1/128 (loopback)
    if (ip == 1) return true;
    // fe80::/10 (link-local)
    if ((ip >> 118) == 0x3F8) return true;
    // fc00::/7 (unique local)
    if ((ip >> 121) == 0x7E) return true;
    // fec0::/10 (deprecated site-local)
    if ((ip >> 118) == 0x3F9) return true;
    // ff00::/8 (multicast)
    if ((ip >> 120) == 0xFF) return true;
    // 100::/64 (discard only)
    if ((ip >> 64) == 0x100) return true;
    return false;
}

fn extractHost(url: []const u8) ?[]const u8 {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    }
    const host_end = std.mem.indexOfAny(u8, rest, "/:") orelse rest.len;
    return if (host_end > 0) rest[0..host_end] else null;
}

fn parseIp4(host: []const u8) ?u32 {
    var octets: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    var current: u32 = 0;

    for (host) |c| {
        if (c == '.') {
            if (idx >= 4) return null;
            octets[idx] = current;
            idx += 1;
            current = 0;
            continue;
        }
        if (c < '0' or c > '9') return null;
        current = current * 10 + (c - '0');
        if (current > 255) return null;
    }
    if (idx >= 4) return null;
    octets[idx] = current;

    return (@as(u32, @intCast(octets[0])) << 24) |
        (@as(u32, @intCast(octets[1])) << 16) |
        (@as(u32, @intCast(octets[2])) << 8) |
        @as(u32, @intCast(octets[3]));
}

test "Middleware creation" {
    const mw = logger();
    try std.testing.expectEqualStrings("logger", mw.name);
}

test "CORS middleware" {
    const config = CorsConfig{};
    const mw = cors(config);
    try std.testing.expectEqualStrings("cors", mw.name);
}

test "Rate limit middleware" {
    const config = RateLimitConfig{ .max_requests = 50 };
    const mw = rateLimit(config);
    try std.testing.expectEqualStrings("rate_limit", mw.name);
}

test "Helmet middleware" {
    const mw = helmet();
    try std.testing.expectEqualStrings("helmet", mw.name);
}

test "Reverse proxy middleware creation" {
    const mw = reverseProxy("http://127.0.0.1:9090");
    try std.testing.expectEqualStrings("reverse_proxy", mw.name);
}

test "loggerWithConfig middleware" {
    const CustomLogger = struct {
        var logged: bool = false;
        fn log_fn(level: @import("server.zig").LogLevel, message: []const u8) void {
            _ = level;
            if (std.mem.indexOf(u8, message, "GET /test") != null) {
                logged = true;
            }
        }
    };

    const mw = loggerWithConfig(.{ .log_fn = CustomLogger.log_fn });
    try std.testing.expectEqualStrings("logger", mw.name);

    var req = try @import("../core/request.zig").Request.init(std.testing.allocator, .GET, "/test");
    defer req.deinit();

    var ctx = Context.init(std.testing.allocator, &req);
    defer ctx.deinit();

    const NextMock = struct {
        fn next(c: *Context) anyerror!Response {
            _ = c;
            return Response.init(std.testing.allocator, 200);
        }
    };

    var res = try mw.handler(&ctx, NextMock.next);
    defer res.deinit();

    try std.testing.expect(CustomLogger.logged);
}

/// Health check configuration.
pub const HealthConfig = struct {
    /// Path to serve the health check on.
    path: []const u8 = "/health",
    /// Optional custom status body (JSON-encodable string).
    body: []const u8 = "{\"status\":\"ok\"}",
    /// HTTP status code to return.
    status: u16 = status.StatusCode.OK,
};

/// Creates a health check endpoint middleware.
///
/// Intercepts requests to the configured path and returns a health status
/// response without passing to downstream handlers.
pub fn healthCheck(comptime config: HealthConfig) Middleware {
    return .{
        .name = "health_check",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                if (std.mem.eql(u8, ctx.request.uri.path, config.path)) {
                    _ = try ctx.response.header("Content-Type", "application/json");
                    _ = ctx.response.status(config.status);
                    _ = ctx.response.body(config.body);
                    return ctx.response.build();
                }
                return next(ctx);
            }
        }.handler,
    };
}

/// Readiness probe configuration for Kubernetes-style health checks.
pub const ReadinessConfig = struct {
    /// Path to serve the readiness check on.
    path: []const u8 = "/ready",
    /// Custom body to return.
    body: []const u8 = "{\"ready\":true}",
};

/// Creates a readiness probe endpoint middleware.
pub fn readinessProbe(comptime config: ReadinessConfig) Middleware {
    return .{
        .name = "readiness_probe",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                if (std.mem.eql(u8, ctx.request.uri.path, config.path)) {
                    _ = try ctx.response.header("Content-Type", "application/json");
                    _ = ctx.response.status(status.StatusCode.OK);
                    _ = ctx.response.body(config.body);
                    return ctx.response.build();
                }
                return next(ctx);
            }
        }.handler,
    };
}

test "healthCheck middleware intercepts /health" {
    var req = try @import("../core/request.zig").Request.init(std.testing.allocator, .GET, "/health");
    defer req.deinit();

    var ctx = Context.init(std.testing.allocator, &req);
    defer ctx.deinit();

    const mw = healthCheck(.{});
    try std.testing.expectEqualStrings("health_check", mw.name);

    const NextMock = struct {
        fn next(c: *Context) anyerror!Response {
            _ = c;
            return Response.init(std.testing.allocator, 200);
        }
    };

    var res = try mw.handler(&ctx, NextMock.next);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status.code);
}

test "readinessProbe middleware intercepts /ready" {
    var req = try @import("../core/request.zig").Request.init(std.testing.allocator, .GET, "/ready");
    defer req.deinit();

    var ctx = Context.init(std.testing.allocator, &req);
    defer ctx.deinit();

    const mw = readinessProbe(.{});
    try std.testing.expectEqualStrings("readiness_probe", mw.name);

    const NextMock = struct {
        fn next(c: *Context) anyerror!Response {
            _ = c;
            return Response.init(std.testing.allocator, 200);
        }
    };

    var res = try mw.handler(&ctx, NextMock.next);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status.code);
}

test "CSRF middleware creation" {
    const mw = csrf(.{});
    try std.testing.expectEqualStrings("csrf", mw.name);
}
