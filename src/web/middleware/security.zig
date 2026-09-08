//! Security middleware primitives: CORS, CSRF, rate limiting.
//!
//! Pure policy logic — no socket/server dependency — so handlers integrate it
//! into any transport (HTTP/1, HTTP/2, HTTP/3) and tests run standalone.
//!
//! References:
//!   - Fetch Standard — CORS (Cross-Origin Resource Sharing)
//!   - RFC 9110 Section 13.1 — Effective Request URI (CORS origin)
//!   - Double-submit cookie pattern for CSRF protection

const std = @import("std");
const Allocator = std.mem.Allocator;

// CORS (Fetch spec / RFC 9110 semantics)

pub const CorsConfig = struct {
    allowed_origins: []const []const u8 = &.{},
    allow_all_origins: bool = false,
    allowed_methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS" },
    allowed_headers: []const []const u8 = &.{},
    exposed_headers: []const []const u8 = &.{},
    allow_credentials: bool = false,
    max_age_seconds: u32 = 600,

    /// Validates the unsafe combination: wildcard origin + credentials.
    pub fn isSafe(self: *const CorsConfig) bool {
        if (self.allow_credentials and self.allow_all_origins) return false;
        return true;
    }

    /// Origin check with exact match against the configured list.
    pub fn isOriginAllowed(self: *const CorsConfig, origin: []const u8) bool {
        if (self.allow_all_origins) return true;
        for (self.allowed_origins) |o| {
            if (std.ascii.eqlIgnoreCase(o, origin)) return true;
        }
        return false;
    }

    pub fn isMethodAllowed(self: *const CorsConfig, method: []const u8) bool {
        for (self.allowed_methods) |m| {
            if (std.ascii.eqlIgnoreCase(m, method)) return true;
        }
        return false;
    }
};

// CSRF tokens

/// Double-submit cookie pattern: constant-time comparison of header token vs
/// cookie token. 32-byte random tokens base64url encoded (43 chars).
pub const CSRF_TOKEN_LEN: usize = 43;

pub fn generateCsrfToken(random: std.Random, out: *[CSRF_TOKEN_LEN]u8) []const u8 {
    var raw: [32]u8 = undefined;
    random.bytes(&raw);
    return std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
}

/// Constant-time match so timing cannot leak token bytes.
pub fn verifyCsrfToken(a: []const u8, b: []const u8) bool {
    if (a.len != CSRF_TOKEN_LEN or b.len != CSRF_TOKEN_LEN) return false;
    return std.crypto.timing_safe.eql([CSRF_TOKEN_LEN]u8, a[0..CSRF_TOKEN_LEN].*, b[0..CSRF_TOKEN_LEN].*);
}

// Rate limiting
pub const rate_limit = @import("rate_limit.zig");
pub const RateLimiter = rate_limit.RateLimiter;
pub const RateLimitError = rate_limit.RateLimitError;
pub const RateLimitDimension = rate_limit.RateLimitDimension;
pub const RateLimitPolicy = rate_limit.RateLimitPolicy;
pub const RateLimitResult = rate_limit.RateLimitResult;

// Tests

test "cors rejects wildcard plus credentials" {
    const unsafe_cfg = CorsConfig{ .allow_all_origins = true, .allow_credentials = true };
    try std.testing.expect(!unsafe_cfg.isSafe());

    const safe_cfg = CorsConfig{ .allow_all_origins = true };
    try std.testing.expect(safe_cfg.isSafe());
}

test "cors origin matching" {
    const cfg = CorsConfig{ .allowed_origins = &.{ "https://a.com", "https://b.com" } };
    try std.testing.expect(cfg.isOriginAllowed("https://A.com"));
    try std.testing.expect(!cfg.isOriginAllowed("https://evil.com"));
    try std.testing.expect(cfg.isMethodAllowed("post"));
    try std.testing.expect(!cfg.isMethodAllowed("TRACE"));
}

test "csrf roundtrip and tamper rejection" {
    var prng = std.Random.DefaultPrng.init(0xC5EED5EED);
    const rng = prng.random();
    var tok_a: [CSRF_TOKEN_LEN]u8 = undefined;
    var tok_b: [CSRF_TOKEN_LEN]u8 = undefined;
    _ = generateCsrfToken(rng, &tok_a);
    _ = generateCsrfToken(rng, &tok_b);

    try std.testing.expect(verifyCsrfToken(&tok_a, &tok_a));
    try std.testing.expect(!verifyCsrfToken(&tok_a, &tok_b));
    // Wrong length always rejected
    try std.testing.expect(!verifyCsrfToken(tok_a[0..10], tok_a[0..10]));
}

test "rate limiter enforces window" {
    var rl = RateLimiter.init(std.testing.allocator, 3, 1000);
    defer rl.deinit();

    try std.testing.expectEqual(@as(?u32, 2), try rl.check("ip:1.2.3.4", 0));
    try std.testing.expectEqual(@as(?u32, 1), try rl.check("ip:1.2.3.4", 5));
    try std.testing.expectEqual(@as(?u32, 0), try rl.check("ip:1.2.3.4", 10));
    // Exhausted within window
    try std.testing.expectEqual(@as(?u32, null), try rl.check("ip:1.2.3.4", 15));
    // New window resets
    try std.testing.expectEqual(@as(?u32, 2), try rl.check("ip:1.2.3.4", 1500));
    // Independent keys
    try std.testing.expectEqual(@as(?u32, 2), try rl.check("ip:5.6.7.8", 10));
}

// Built-in composable middlewares

const router_mod = @import("../router/router.zig");
const Context = router_mod.Context;
const Response = router_mod.Response;
const NextFn = router_mod.NextFn;
const Header = router_mod.Header;

/// Standard CORS middleware handling preflight OPTIONS and response headers.
pub fn corsMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    if (ctx.method == .OPTIONS) {
        return Response{
            .status = 204,
            .body = "",
            .headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization, Accept, Origin, X-Requested-With" },
                .{ .name = "Access-Control-Max-Age", .value = "86400" },
            },
        };
    }
    var resp = try next(ctx);
    const extra = try ctx.allocator.alloc(Header, resp.headers.len + 1);
    @memcpy(extra[0..resp.headers.len], resp.headers);
    extra[resp.headers.len] = .{ .name = "Access-Control-Allow-Origin", .value = "*" };
    resp.headers = extra;
    return resp;
}

/// Sets standard defensive HTTP security headers.
pub fn securityHeadersMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    var resp = try next(ctx);
    const sec_hdrs = [_]Header{
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "X-Frame-Options", .value = "DENY" },
        .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
        .{ .name = "Content-Security-Policy", .value = "default-src 'self'" },
    };
    const extra = try ctx.allocator.alloc(Header, resp.headers.len + sec_hdrs.len);
    @memcpy(extra[0..resp.headers.len], resp.headers);
    @memcpy(extra[resp.headers.len..], &sec_hdrs);
    resp.headers = extra;
    return resp;
}

/// Catches uncaught handler errors and returns a 500 response without panicking.
pub fn recoveryMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    return next(ctx) catch {
        return Response{
            .status = 500,
            .content_type = "text/plain; charset=utf-8",
            .body = "Internal Server Error",
        };
    };
}

/// Logs request method, path, and response status.
pub fn loggingMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    return next(ctx);
}

test "middleware pipeline execution and headers" {
    const a = std.testing.allocator;
    var router = router_mod.Router.init(a);
    defer router.deinit();

    try router.use(corsMiddleware);
    try router.use(securityHeadersMiddleware);

    const dummy = struct {
        fn handle(ctx: *Context) anyerror!Response {
            return ctx.text("hello middleware");
        }
        fn fail(ctx: *Context) anyerror!Response {
            _ = ctx;
            return error.Explosion;
        }
    };

    try router.get("/test", dummy.handle);
    try router.get("/fail", dummy.fail);

    // Test GET /test runs through cors and security headers
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ctx = Context{ .allocator = arena.allocator(), .path = "/test", .method = .GET };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("hello middleware", resp.body);
        try std.testing.expect(resp.headers.len >= 5);
    }

    // Test OPTIONS /test returns 204 preflight
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ctx = Context{ .allocator = arena.allocator(), .path = "/test", .method = .OPTIONS };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 204), resp.status);
    }

    // Test recovery middleware on failing route
    {
        try router.use(recoveryMiddleware);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ctx = Context{ .allocator = arena.allocator(), .path = "/fail", .method = .GET };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 500), resp.status);
    }
}
