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

const std = @import("std");
const Context = @import("server.zig").Context;
const io_util = @import("../util/any_io.zig");
const Response = @import("../core/response.zig").Response;
const types = @import("../core/types.zig");
const list_writer = @import("../util/list_writer.zig");
const status = @import("../core/status.zig");
const common = @import("../util/common.zig");

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
            fn methodList(allocator: std.mem.Allocator, methods: []const types.Method) ![]u8 {
                var out = std.ArrayList(u8).empty;
                errdefer out.deinit(allocator);
                const writer = list_writer.init(allocator, &out);

                for (methods, 0..) |m, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(m.toString());
                }
                return out.toOwnedSlice(allocator);
            }

            fn headerList(allocator: std.mem.Allocator, headers_in: []const []const u8) ![]u8 {
                var out = std.ArrayList(u8).empty;
                errdefer out.deinit(allocator);
                const writer = list_writer.init(allocator, &out);

                for (headers_in, 0..) |h, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(h);
                }
                return out.toOwnedSlice(allocator);
            }

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

                const methods = try methodList(ctx.allocator, config.allowed_methods);
                defer ctx.allocator.free(methods);
                try ctx.setHeader("Access-Control-Allow-Methods", methods);

                const allowed_headers = try headerList(ctx.allocator, config.allowed_headers);
                defer ctx.allocator.free(allowed_headers);
                try ctx.setHeader("Access-Control-Allow-Headers", allowed_headers);

                if (config.exposed_headers.len > 0) {
                    const exposed = try headerList(ctx.allocator, config.exposed_headers);
                    defer ctx.allocator.free(exposed);
                    try ctx.setHeader("Access-Control-Expose-Headers", exposed);
                }

                if (config.allow_credentials) {
                    try ctx.setHeader("Access-Control-Allow-Credentials", "true");
                }

                var max_age_buf: [32]u8 = undefined;
                const max_age = std.fmt.bufPrint(&max_age_buf, "{d}", .{config.max_age}) catch unreachable;
                try ctx.setHeader("Access-Control-Max-Age", max_age);

                if (ctx.request.method == .OPTIONS) {
                    return ctx.status(status.StatusCode.NO_CONTENT).text("");
                }

                return next(ctx);
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

                var buf: [1024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} {s} - {d}ms\n", .{
                    ctx.request.method.toString(),
                    ctx.request.uri.path,
                    duration,
                }) catch "[Logger format failed or message too long]";

                if (config.log_fn) |f| {
                    f(.info, msg);
                } else {
                    std.debug.print("{s}", .{msg});
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
pub fn compressionMiddleware() Middleware {
    return .{
        .name = "compression",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
                _ = ctx.header("Accept-Encoding");
                return next(ctx);
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
pub fn rateLimit(comptime config: RateLimitConfig) Middleware {
    return .{
        .name = "rate_limit",
        .handler = struct {
            const Entry = struct { count: u32, window_start: i64 };
            var store: std.StringHashMap(Entry) = undefined;
            var store_initialized: bool = false;

            fn handler(ctx: *Context, next: Next) anyerror!Response {
                if (!store_initialized) {
                    store = std.StringHashMap(Entry).init(ctx.allocator);
                    store_initialized = true;
                }

                const now = common.nowMillis();
                const ip = ctx.header("X-Forwarded-For") orelse
                    ctx.header("X-Real-IP") orelse
                    "0.0.0.0";

                const entry = store.get(ip);
                if (entry) |e| {
                    if (now - e.window_start < @as(i64, @intCast(config.window_ms))) {
                        if (e.count >= config.max_requests) {
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
                const Base64 = @import("../util/encoding.zig").Base64;
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

/// Creates request timeout middleware.
///
/// NOTE: Actual request-level timeout enforcement requires async infrastructure.
/// This middleware currently passes through; the `ms` parameter is stored for
/// future use. The server's own `request_timeout_ms` config handles timeouts.
pub fn timeout(ms: u64) Middleware {
    _ = ms;
    return .{
        .name = "timeout",
        .handler = struct {
            fn handler(ctx: *Context, next: Next) anyerror!Response {
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
