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

// Rate limiting: sliding window counters per key

pub const RateLimitError = error{OutOfMemory};

pub const RateLimiter = struct {
    const Entry = struct {
        window_start_ms: i64,
        count: u32,
    };

    allocator: Allocator,
    map: std.StringHashMap(Entry),
    max_requests: u32,
    window_ms: i64,

    pub fn init(allocator: Allocator, max_requests: u32, window_ms: i64) RateLimiter {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
            .max_requests = max_requests,
            .window_ms = window_ms,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    /// Returns remaining quota, or null when the request must be rejected.
    /// key: caller-owned string like "ip:1.2.3.4" or "route:/api".
    pub fn check(self: *RateLimiter, key: []const u8, now_ms: i64) !?u32 {
        const gop = try self.map.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = .{ .window_start_ms = now_ms, .count = 0 };
        }
        const e = gop.value_ptr;
        if (now_ms - e.window_start_ms >= self.window_ms) {
            e.* = .{ .window_start_ms = now_ms, .count = 0 };
        }
        if (e.count >= self.max_requests) return null;
        e.count += 1;
        return self.max_requests - e.count;
    }
};

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
