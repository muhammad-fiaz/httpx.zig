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
const tint = @import("tint");
const Context = @import("server.zig").Context;
const io_util = @import("../util/any_io.zig");
const Response = @import("../core/response.zig").Response;
const types = @import("../core/types.zig");
const list_writer = @import("../util/list_writer.zig");
const status = @import("../core/status.zig");
const common = @import("../util/common.zig");
const compression_util = @import("../util/compression.zig");
const dbg = @import("../util/debug.zig");

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
                dbg.entry("MW", "cors");
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
                dbg.exit("MW", "cors");
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
                dbg.log("MW", "logger {s} {s}", .{ ctx.request.method.toString(), ctx.request.uri.path });
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
    min_bytes: usize = 1024,
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

                    const accept = ctx.header("Accept-Encoding") orelse return resp;
                    const encoding = pickEncoding(accept) orelse return resp;

                    var new_resp = resp;
                    if (compression_util.compress(ctx.allocator, encoding, body)) |compressed| {
                        new_resp.body = compressed;
                        new_resp.body_owned = true;
                        ctx.setHeader("Content-Encoding", encoding.toString()) catch {};
                        ctx.setHeader("Vary", "Accept-Encoding") catch {};
                    } else |_| {}
                    return new_resp;
                }
                return resp;
            }

            fn pickEncoding(accept: []const u8) ?compression_util.ContentEncoding {
                if (std.ascii.indexOfIgnoreCase(accept, "br") != null) return .br;
                if (std.ascii.indexOfIgnoreCase(accept, "zstd") != null) return .zstd;
                if (std.ascii.indexOfIgnoreCase(accept, "gzip") != null) return .gzip;
                if (std.ascii.indexOfIgnoreCase(accept, "deflate") != null) return .deflate;
                return null;
            }
        }.handler,
    };
}

/// Rate limiting configuration.
pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u64 = 60_000,
};

/// Creates rate limiting middleware.
///
/// Tracks request counts in an in-memory hashmap keyed by IP.
/// Returns 429 Too Many Requests when the limit is exceeded.
/// Evicts stale entries periodically to prevent unbounded memory growth.
/// Thread-safe: protected by a mutex for concurrent access.
pub fn rateLimit(comptime config: RateLimitConfig) Middleware {
    return .{
        .name = "rate_limit",
        .handler = struct {
            const Entry = struct { count: u32, window_start: i64 };
            var store: std.StringHashMap(Entry) = undefined;
            var store_initialized: bool = false;
            var evict_counter: u32 = 0;
            var mu: std.Io.Mutex = .init;

            fn handler(ctx: *Context, next: Next) anyerror!Response {
                dbg.entry("MW", "rateLimit");
                if (!store_initialized) {
                    store = std.StringHashMap(Entry).init(ctx.allocator);
                    store_initialized = true;
                }

                const now = common.nowMillis();
                const ip = ctx.header("X-Forwarded-For") orelse
                    ctx.header("X-Real-IP") orelse
                    "0.0.0.0";

                const io = io_util.defaultIo();
                mu.lock(io) catch unreachable;
                defer mu.unlock(io);

                // Evict stale entries every 512 requests to prevent unbounded growth.
                evict_counter +%= 1;
                if (evict_counter % 512 == 0) {
                    var it = store.iterator();
                    while (it.next()) |kv| {
                        if (now - kv.value_ptr.window_start > @as(i64, @intCast(config.window_ms * 2))) {
                            _ = store.remove(kv.key_ptr.*);
                        }
                    }
                }

                const entry = store.get(ip);
                if (entry) |e| {
                    if (now - e.window_start < @as(i64, @intCast(config.window_ms))) {
                        if (e.count >= config.max_requests) {
                            dbg.log("MW", "rate limit exceeded for {s}", .{ip});
                            try ctx.setHeader("Retry-After", "60");
                            return ctx.status(status.StatusCode.TOO_MANY_REQUESTS).text("Too Many Requests");
                        }
                        try store.put(ip, .{ .count = e.count + 1, .window_start = e.window_start });
                    } else {
                        try store.put(ip, .{ .count = 1, .window_start = now });
                    }
                } else {
                    try store.put(ip, .{ .count = 1, .window_start = now });
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
                dbg.entry("MW", "basicAuth");
                const auth = ctx.header("Authorization") orelse {
                    dbg.log("MW", "basicAuth failed: no Authorization header", .{});
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };

                if (!std.mem.startsWith(u8, auth, "Basic ")) {
                    dbg.log("MW", "basicAuth failed: not Basic prefix", .{});
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                }

                const encoded = std.mem.trim(u8, auth[6..], " \t");
                const Base64 = @import("../util/encoding.zig").Base64;
                const decoded = Base64.decode(ctx.allocator, encoded) catch {
                    dbg.log("MW", "basicAuth failed: bad base64", .{});
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };
                defer ctx.allocator.free(decoded);

                const colon_pos = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                    dbg.log("MW", "basicAuth failed: missing colon", .{});
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                };

                const username = decoded[0..colon_pos];
                const password = decoded[colon_pos + 1 ..];

                if (!validator(username, password)) {
                    dbg.log("MW", "basicAuth failed: invalid credentials", .{});
                    const www_auth = try std.fmt.allocPrint(ctx.allocator, "Basic realm=\"{s}\"", .{realm});
                    defer ctx.allocator.free(www_auth);
                    try ctx.setHeader("WWW-Authenticate", www_auth);
                    return ctx.status(status.StatusCode.UNAUTHORIZED).text("Unauthorized");
                }

                dbg.log("MW", "basicAuth success for user {s}", .{username});
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
/// X-XSS-Protection, and Strict-Transport-Security.
pub fn helmet() Middleware {
    return .{
        .name = "helmet",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                try ctx.setHeader("X-Content-Type-Options", "nosniff");
                try ctx.setHeader("X-Frame-Options", "DENY");
                try ctx.setHeader("X-XSS-Protection", "1; mode=block");
                try ctx.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
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
pub fn csrf(comptime config: CsrfConfig) Middleware {
    return .{
        .name = "csrf",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                dbg.entry("MW", "csrf");

                // Only protect state-changing methods.
                const method = ctx.request.method;
                if (method == .GET or method == .HEAD or method == .OPTIONS) {
                    return next(ctx);
                }

                // Generate or retrieve token from cookie.
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
                        if (std.mem.eql(u8, ct, rt)) {
                            return next(ctx);
                        }
                    }
                    dbg.log("MW", "CSRF token mismatch", .{});
                    return ctx.status(status.StatusCode.FORBIDDEN).text("CSRF token mismatch");
                }

                // No cookie yet — set one and let the request through.
                // The client must include this token in subsequent requests.
                var raw: [32]u8 = undefined;
                io_util.defaultIo().random(&raw);
                const token = try std.fmt.allocPrint(ctx.allocator, "{s}", .{raw});
                defer ctx.allocator.free(token);

                try ctx.setCookie(config.cookie_name, token, .{
                    .same_site = .lax,
                    .http_only = true,
                    .secure = config.secure,
                    .path = "/",
                });

                return next(ctx);
            }
        }.handler,
    };
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
                    dbg.log("MW", "SSRF blocked: {s}", .{full_target});
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
                    dbg.log("MW", "SSRF blocked: {s}", .{full_target});
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
fn isSsrfBlocked(url: []const u8) bool {
    const host = extractHost(url) orelse return false;

    // Check common internal hostnames.
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "0.0.0.0") or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]"))
    {
        return true;
    }

    // Parse IPv4 and check private ranges.
    const ip = parseIp4(host) orelse return false;

    // 127.0.0.0/8
    if ((ip >> 24) == 0x7F) return true;
    // 10.0.0.0/8
    if ((ip >> 24) == 0x0A) return true;
    // 172.16.0.0/12
    if ((ip >> 20) == 0xAC1) return true;
    // 192.168.0.0/16
    if ((ip >> 16) == 0xC0A8) return true;
    // 0.0.0.0/8
    if ((ip >> 24) == 0) return true;
    // 169.254.0.0/16 (link-local)
    if ((ip >> 16) == 0xA9FE) return true;
    // 198.18.0.0/15 (benchmarking)
    if ((ip >> 15) == 0x6009) return true;

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
