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
const regexMod = @import("regex");

// CORS (Fetch spec / RFC 9110 semantics)

pub const CorsConfig = struct {
    allowedOrigins: []const []const u8 = &.{},
    /// Optional regex patterns for origins (e.g. "^https://[a-z0-9-]+\\.example\\.com$").
    allowedOriginPatterns: []const []const u8 = &.{},
    allowAllOrigins: bool = false,
    allowedMethods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS" },
    allowedHeaders: []const []const u8 = &.{},
    exposedHeaders: []const []const u8 = &.{},
    allowCredentials: bool = false,
    maxAgeSeconds: u32 = 600,

    /// Validates the unsafe combination: wildcard origin + credentials.
    pub fn isSafe(self: *const CorsConfig) bool {
        if (self.allowCredentials and self.allowAllOrigins) return false;
        return true;
    }

    /// Origin check with exact match or wildcard (*) pattern matching.
    pub fn isOriginAllowed(self: *const CorsConfig, origin: []const u8) bool {
        if (self.allowAllOrigins) return true;
        for (self.allowedOrigins) |o| {
            if (std.ascii.eqlIgnoreCase(o, origin)) return true;
            if (std.mem.indexOfScalar(u8, o, '*') != null) {
                if (matchOriginWildcard(o, origin)) return true;
            }
        }
        return false;
    }

    /// Origin check supporting both static wildcards and regex patterns using the supplied allocator.
    pub fn isOriginAllowedAlloc(self: *const CorsConfig, allocator: Allocator, origin: []const u8) bool {
        if (self.isOriginAllowed(origin)) return true;
        for (self.allowedOriginPatterns) |pattern| {
            var re = regexMod.compile(allocator, pattern, .{}) catch continue;
            defer re.deinit();
            if (re.isMatch(origin, .{})) return true;
        }
        return false;
    }

    pub fn isMethodAllowed(self: *const CorsConfig, method: []const u8) bool {
        for (self.allowedMethods) |m| {
            if (std.ascii.eqlIgnoreCase(m, method)) return true;
        }
        return false;
    }
};

fn matchOriginWildcard(pattern: []const u8, origin: []const u8) bool {
    const starIdx = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.ascii.eqlIgnoreCase(pattern, origin);
    const prefix = pattern[0..starIdx];
    const suffix = pattern[starIdx + 1 ..];
    if (origin.len < prefix.len + suffix.len) return false;
    if (!std.ascii.startsWithIgnoreCase(origin, prefix)) return false;
    if (!std.ascii.endsWithIgnoreCase(origin, suffix)) return false;
    return true;
}

// CSRF tokens

/// Double-submit cookie pattern: constant-time comparison of header token vs
/// cookie token. 32-byte random tokens base64url encoded (43 chars).
pub const CSRF_TOKEN_LEN: usize = 43;

/// Mints a CSRF token from OS entropy. This is the one to use.
///
/// The token is the entire secret behind the double-submit pattern: a
/// predictable token means an attacker who can read one victim's page
/// can forge that victim's request, so the source has to be a CSPRNG.
pub fn generateCsrfTokenSecure(io: std.Io, out: *[CSRF_TOKEN_LEN]u8) ![]const u8 {
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    return std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
}

/// Mints a CSRF token from a caller-supplied generator.
///
/// **Test-only.** `std.Random` carries no secrecy guarantee, so passing
/// a `DefaultPrng` here yields a token an attacker can predict, which
/// silently defeats CSRF protection. Use `generateCsrfTokenSecure` in
/// server code; this variant exists so tests can pin the value.
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
pub const rateLimit = @import("rateLimiter.zig");
pub const RateLimiter = rateLimit.RateLimiter;
pub const RateLimitError = rateLimit.RateLimitError;
pub const RateLimitDimension = rateLimit.RateLimitDimension;
pub const RateLimitPolicy = rateLimit.RateLimitPolicy;
pub const RateLimitResult = rateLimit.RateLimitResult;

// Tests

test "cors rejects wildcard plus credentials" {
    const unsafeCfg = CorsConfig{ .allowAllOrigins = true, .allowCredentials = true };
    try std.testing.expect(!unsafeCfg.isSafe());

    const safeCfg = CorsConfig{ .allowAllOrigins = true };
    try std.testing.expect(safeCfg.isSafe());
}

test "cors origin matching" {
    const cfg = CorsConfig{ .allowedOrigins = &.{ "https://a.com", "https://b.com" } };
    try std.testing.expect(cfg.isOriginAllowed("https://A.com"));
    try std.testing.expect(!cfg.isOriginAllowed("https://evil.com"));
    try std.testing.expect(cfg.isMethodAllowed("post"));
    try std.testing.expect(!cfg.isMethodAllowed("TRACE"));
}

test "cors wildcard and regex pattern origin matching" {
    const a = std.testing.allocator;
    const cfg = CorsConfig{
        .allowedOrigins = &.{ "https://*.example.com", "http://localhost:*" },
        .allowedOriginPatterns = &.{"^https://app-[0-9]+\\.internal\\.net$"},
    };

    // Wildcard matching in allowedOrigins
    try std.testing.expect(cfg.isOriginAllowed("https://api.example.com"));
    try std.testing.expect(cfg.isOriginAllowed("https://admin.dashboard.example.com"));
    try std.testing.expect(cfg.isOriginAllowed("http://localhost:3000"));
    try std.testing.expect(cfg.isOriginAllowed("http://localhost:8080"));
    try std.testing.expect(!cfg.isOriginAllowed("https://evil.com"));
    try std.testing.expect(!cfg.isOriginAllowed("https://example.org"));

    // Regex pattern matching via isOriginAllowedAlloc
    try std.testing.expect(cfg.isOriginAllowedAlloc(a, "https://app-42.internal.net"));
    try std.testing.expect(cfg.isOriginAllowedAlloc(a, "https://app-101.internal.net"));
    try std.testing.expect(!cfg.isOriginAllowedAlloc(a, "https://app-abc.internal.net"));
    try std.testing.expect(!cfg.isOriginAllowedAlloc(a, "https://malicious.net"));
}

test "csrf roundtrip and tamper rejection" {
    var prng = std.Random.DefaultPrng.init(0xC5EED5EED);
    const rng = prng.random();
    var tokA: [CSRF_TOKEN_LEN]u8 = undefined;
    var tokB: [CSRF_TOKEN_LEN]u8 = undefined;
    _ = generateCsrfToken(rng, &tokA);
    _ = generateCsrfToken(rng, &tokB);

    try std.testing.expect(verifyCsrfToken(&tokA, &tokA));
    try std.testing.expect(!verifyCsrfToken(&tokA, &tokB));
    // Wrong length always rejected
    try std.testing.expect(!verifyCsrfToken(tokA[0..10], tokA[0..10]));
}

test "rate limiter enforces window" {
    var rl = RateLimiter.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), .{ .policy = .{ .limit = 3, .windowMs = 1000 } });
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

const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const NextFn = routerMod.NextFn;
const Header = routerMod.Header;

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
    const secHdrs = [_]Header{
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "X-Frame-Options", .value = "DENY" },
        .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
        .{ .name = "Content-Security-Policy", .value = "default-src 'self'" },
    };
    const extra = try ctx.allocator.alloc(Header, resp.headers.len + secHdrs.len);
    @memcpy(extra[0..resp.headers.len], resp.headers);
    @memcpy(extra[resp.headers.len..], &secHdrs);
    resp.headers = extra;
    return resp;
}

/// Catches uncaught handler errors and returns a 500 response without panicking.
pub fn recoveryMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    return next(ctx) catch {
        return Response{
            .status = 500,
            .contentType = "text/plain; charset=utf-8",
            .body = "Internal Server Error",
        };
    };
}

/// Logs request method, path, and response status.
pub fn loggingMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    return next(ctx);
}

pub const CsrfConfig = struct {
    cookieName: []const u8 = "csrf_token",
    headerName: []const u8 = "X-CSRF-Token",
    cookiePath: []const u8 = "/",
    cookieSameSite: []const u8 = "Lax",
    cookieSecure: bool = false,
};

/// Automated CSRF middleware using the double-submit cookie pattern.
///
/// For safe methods (GET, HEAD, OPTIONS, TRACE):
/// - Checks if the CSRF cookie is present; if absent, generates a secure random token
///   and sets the Set-Cookie response header.
///
/// For state-changing methods (POST, PUT, DELETE, PATCH):
/// - Compares the token from the header (default: "X-CSRF-Token") with the token from the
///   CSRF cookie using constant-time comparison.
/// - If either is missing or they do not match, returns 403 Forbidden.
pub fn csrfMiddleware(ctx: *Context, next: NextFn) anyerror!Response {
    return csrfMiddlewareConfig(ctx, next, .{});
}

pub fn csrfMiddlewareConfig(ctx: *Context, next: NextFn, cfg: CsrfConfig) anyerror!Response {
    const isSafe = switch (ctx.method) {
        .GET, .HEAD, .OPTIONS, .TRACE => true,
        else => false,
    };

    const existingCookie = ctx.cookie(cfg.cookieName);

    if (isSafe) {
        var resp = try next(ctx);
        if (existingCookie == null) {
            var tokenBuf: [CSRF_TOKEN_LEN]u8 = undefined;
            const token = try generateCsrfTokenSecure(ctx.io, &tokenBuf);

            const setCookieVal = try std.fmt.allocPrint(ctx.allocator, "{s}={s}; Path={s}; SameSite={s}{s}", .{
                cfg.cookieName,
                token,
                cfg.cookiePath,
                cfg.cookieSameSite,
                if (cfg.cookieSecure) "; Secure" else "",
            });

            const extra = try ctx.allocator.alloc(Header, resp.headers.len + 1);
            @memcpy(extra[0..resp.headers.len], resp.headers);
            extra[resp.headers.len] = .{ .name = "Set-Cookie", .value = setCookieVal };
            resp.headers = extra;
        }
        return resp;
    }

    const cookieToken = existingCookie orelse {
        return Response{
            .status = 403,
            .contentType = "text/plain; charset=utf-8",
            .body = "CSRF Token Missing",
        };
    };

    const headerToken = ctx.header(cfg.headerName) orelse {
        return Response{
            .status = 403,
            .contentType = "text/plain; charset=utf-8",
            .body = "CSRF Header Missing",
        };
    };

    if (!verifyCsrfToken(cookieToken, headerToken)) {
        return Response{
            .status = 403,
            .contentType = "text/plain; charset=utf-8",
            .body = "CSRF Token Mismatch",
        };
    }

    return next(ctx);
}

test "middleware pipeline execution and headers" {
    const a = std.testing.allocator;
    var router = routerMod.Router.init(a);
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

    try router.get("/test", dummy.handle, .{});
    try router.get("/fail", dummy.fail, .{});

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

test "csrfMiddleware sets cookie on safe methods and enforces on POST" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var router = routerMod.Router.init(a);
    defer router.deinit();

    try router.use(csrfMiddleware);

    const handler = struct {
        fn get(ctx: *Context) anyerror!Response {
            return ctx.text("form page");
        }
        fn submit(ctx: *Context) anyerror!Response {
            return ctx.text("form submitted");
        }
    };

    try router.get("/form", handler.get, .{});
    try router.post("/form", handler.submit, .{});

    // 1. GET request without cookie: should receive Set-Cookie
    var cookieToken: [CSRF_TOKEN_LEN]u8 = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ctx = Context{ .allocator = arena.allocator(), .io = io, .path = "/form", .method = .GET };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("form page", resp.body);

        var foundCookie: ?[]const u8 = null;
        for (resp.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie") and std.mem.startsWith(u8, h.value, "csrf_token=")) {
                foundCookie = h.value;
                break;
            }
        }
        try std.testing.expect(foundCookie != null);
        const tokPart = foundCookie.?[11..];
        const endIdx = std.mem.indexOfScalar(u8, tokPart, ';') orelse tokPart.len;
        try std.testing.expectEqual(CSRF_TOKEN_LEN, endIdx);
        @memcpy(&cookieToken, tokPart[0..CSRF_TOKEN_LEN]);
    }

    // 2. POST without any cookie or header: 403 CSRF Token Missing
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ctx = Context{ .allocator = arena.allocator(), .io = io, .path = "/form", .method = .POST };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
        try std.testing.expectEqualStrings("CSRF Token Missing", resp.body);
    }

    // 3. POST with cookie but missing header: 403 CSRF Header Missing
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const cookieHdrVal = try std.fmt.allocPrint(arena.allocator(), "csrf_token={s}", .{&cookieToken});
        const reqHdrs = [_]Header{.{ .name = "Cookie", .value = cookieHdrVal }};
        var ctx = Context{
            .allocator = arena.allocator(),
            .io = io,
            .path = "/form",
            .method = .POST,
            .headers = &reqHdrs,
        };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
        try std.testing.expectEqualStrings("CSRF Header Missing", resp.body);
    }

    // 4. POST with cookie but mismatched header: 403 CSRF Token Mismatch
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const cookieHdrVal = try std.fmt.allocPrint(arena.allocator(), "csrf_token={s}", .{&cookieToken});
        const reqHdrs = [_]Header{
            .{ .name = "Cookie", .value = cookieHdrVal },
            .{ .name = "X-CSRF-Token", .value = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        };
        var ctx = Context{
            .allocator = arena.allocator(),
            .io = io,
            .path = "/form",
            .method = .POST,
            .headers = &reqHdrs,
        };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
        try std.testing.expectEqualStrings("CSRF Token Mismatch", resp.body);
    }

    // 5. POST with matching cookie and header: 200 OK form submitted!
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const cookieHdrVal = try std.fmt.allocPrint(arena.allocator(), "csrf_token={s}", .{&cookieToken});
        const reqHdrs = [_]Header{
            .{ .name = "Cookie", .value = cookieHdrVal },
            .{ .name = "X-CSRF-Token", .value = &cookieToken },
        };
        var ctx = Context{
            .allocator = arena.allocator(),
            .io = io,
            .path = "/form",
            .method = .POST,
            .headers = &reqHdrs,
        };
        const resp = router.dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("form submitted", resp.body);
    }
}
