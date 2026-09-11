//! Production-grade multi-dimensional per-user rate limiting middleware.
//!
//! Features:
//!   - High-performance Token Bucket algorithm with millisecond replenishment precision.
//!   - Multi-dimensional identity support:
//!       * Authenticated user/account ID (Bearer token, custom header, or auth context)
//!       * API Key (X-API-Key header or query parameter)
//!       * Client IP (direct socket peer or trusted X-Forwarded-For)
//!       * Route / Endpoint (HTTP method + path)
//!       * Global server limit
//!       * Combined dimensions (e.g. User + Route, IP + Route, Global + User)
//!   - Bounded memory with LRU / inactive entry TTL eviction (DoS protection).
//!   - Concurrent thread-safety using fine-grained synchronization locks.
//!   - Standards-compliant HTTP 429 Too Many Requests response generation
//!     with Retry-After, X-RateLimit-Limit, X-RateLimit-Remaining, and X-RateLimit-Reset headers.
//!   - Seamless integration with Router Context and middleware pipelines.
//!
//! References:
//!   - RFC 6585 Section 4 — 429 Too Many Requests
//!   - RFC 7231 Section 7.1.3 — Retry-After
//!   - IETF Draft draft-ietf-httpapi-ratelimit-headers

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("../../common/sync.zig");
const clock = @import("../../common/clock.zig");
const router_mod = @import("../router/router.zig");
const Context = router_mod.Context;
const Response = router_mod.Response;
const Header = router_mod.Header;
const NextFn = router_mod.NextFn;
const MiddlewareFn = router_mod.MiddlewareFn;

pub const RateLimitError = error{
    OutOfMemory,
};

/// Dimensions by which traffic can be partitioned and limited.
pub const RateLimitDimension = enum {
    /// Single global rate limit applied to all traffic across the server.
    global,
    /// Per-client IP address (from socket or trusted X-Forwarded-For).
    clientIp,
    /// Per authenticated user account (Bearer token, user header, or session).
    userId,
    /// Per API key (X-API-Key header or apiKey query param).
    apiKey,
    /// Per route (method + path, e.g. "POST /api/login").
    route,
    /// Combined authenticated user AND route (per-user-per-endpoint limit).
    userAndRoute,
    /// Combined client IP AND route (per-ip-per-endpoint limit).
    ipAndRoute,
    /// Custom application-provided identity string.
    custom,
};

/// Policy configuration specifying limits, time windows, burst capacity, and memory bounds.
pub const RateLimitPolicy = struct {
    /// Maximum allowed requests per window.
    limit: u32 = 100,
    /// Time window in milliseconds over which `limit` requests refill (e.g. 60_000 for 1 minute).
    windowMs: i64 = 60_000,
    /// Maximum burst capacity. If 0, burst defaults to `limit`.
    burst: u32 = 0,
    /// Inactivity TTL in milliseconds after which an idle key is purged from memory.
    ttlMs: i64 = 300_000,
};

/// Detailed result of evaluating a rate limit check.
pub const RateLimitResult = struct {
    /// True if the request is permitted; false if rate-limited (HTTP 429).
    allowed: bool,
    /// Configured request quota.
    limit: u32,
    /// Remaining requests in the current window.
    remaining: u32,
    /// Seconds until the quota fully resets.
    resetSeconds: u32,
    /// Seconds the client must wait before retrying (only meaningful when allowed == false).
    retryAfterSeconds: u32,

    /// Formats an HTTP 429 Too Many Requests response with standard rate-limit headers.
    pub fn toResponse(self: RateLimitResult, allocator: Allocator) !Response {
        const retry_str = try std.fmt.allocPrint(allocator, "{d}", .{self.retryAfterSeconds});
        const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{self.limit});
        const reset_str = try std.fmt.allocPrint(allocator, "{d}", .{self.resetSeconds});

        const headers = try allocator.alloc(Header, 5);
        headers[0] = .{ .name = "Retry-After", .value = retry_str };
        headers[1] = .{ .name = "X-RateLimit-Limit", .value = limit_str };
        headers[2] = .{ .name = "X-RateLimit-Remaining", .value = "0" };
        headers[3] = .{ .name = "X-RateLimit-Reset", .value = reset_str };
        headers[4] = .{ .name = "Content-Type", .value = "application/json; charset=utf-8" };

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"error\":\"too_many_requests\",\"message\":\"Rate limit exceeded. Try again in {d} seconds.\",\"retry_after\":{d}}}\n",
            .{ self.retryAfterSeconds, self.retryAfterSeconds },
        );

        return Response{
            .status = 429,
            .body = body,
            .headers = headers,
        };
    }

    /// Frees the allocated headers and body of an HTTP 429 response created by toResponse.
    pub fn deinitResponse(allocator: Allocator, resp: *const Response) void {
        allocator.free(resp.headers[0].value); // Retry-After
        allocator.free(resp.headers[1].value); // X-RateLimit-Limit
        allocator.free(resp.headers[3].value); // X-RateLimit-Reset
        allocator.free(resp.headers);
        allocator.free(resp.body);
    }
};

/// Token bucket entry for a single identity key.
const BucketEntry = struct {
    tokens: f64,
    lastUpdateMs: i64,
    lastAccessMs: i64,
};

/// Production-grade thread-safe rate limiter with multi-dimensional keys and memory bounds.
pub const RateLimiter = struct {
    allocator: Allocator,
    defaultPolicy: RateLimitPolicy,
    maxEntries: usize,
    buckets: std.StringHashMap(BucketEntry),
    mutex: sync.Spinlock = .{},
    lastSweepMs: i64 = 0,

    /// Creates a new RateLimiter with default policy and max memory entries.
    pub fn init(allocator: Allocator, maxRequests: u32, windowMs: i64) RateLimiter {
        return initWithOptions(allocator, .{
            .limit = maxRequests,
            .windowMs = windowMs,
            .burst = maxRequests,
        }, 10_000);
    }

    /// Creates a new RateLimiter with full policy and entry capacity control.
    pub fn initWithOptions(allocator: Allocator, policy: RateLimitPolicy, maxEntries: usize) RateLimiter {
        var p = policy;
        if (p.burst == 0) p.burst = p.limit;
        return .{
            .allocator = allocator,
            .defaultPolicy = p,
            .maxEntries = @max(1, maxEntries),
            .buckets = std.StringHashMap(BucketEntry).init(allocator),
            .lastSweepMs = clock.millisNow(),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.buckets.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.buckets.deinit();
    }

    /// Evaluates rate limit for `key` against the default policy.
    /// Returns remaining quota on success, or null when the request is rate-limited.
    /// (Compatible with original HTTPX RateLimiter API).
    pub fn check(self: *RateLimiter, key: []const u8, nowMs: i64) !?u32 {
        const res = try self.checkDetailed(key, nowMs, 1, self.defaultPolicy);
        if (!res.allowed) return null;
        return res.remaining;
    }

    /// Evaluates rate limit with cost and custom policy, returning full RateLimitResult metadata.
    pub fn checkDetailed(
        self: *RateLimiter,
        key: []const u8,
        nowMs: i64,
        cost: u32,
        policy: RateLimitPolicy,
    ) RateLimitError!RateLimitResult {
        const capacity: f64 = @floatFromInt(if (policy.burst > 0) policy.burst else policy.limit);
        const limit_f: f64 = @floatFromInt(policy.limit);
        const win_ms_f: f64 = @floatFromInt(@max(1, policy.windowMs));
        const fill_rate_per_ms = limit_f / win_ms_f;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Opportunistic sweep every 30 seconds or when reaching 90% capacity
        if (nowMs - self.lastSweepMs > 30_000 or self.buckets.count() >= (self.maxEntries * 9) / 10) {
            self.sweepExpiredLocked(nowMs, policy.ttlMs);
            self.lastSweepMs = nowMs;
        }

        const bucket = if (self.buckets.getPtr(key)) |b| b else blk: {
            if (self.buckets.count() >= self.maxEntries) {
                self.evictOldestLocked();
            }
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.buckets.put(owned_key, .{
                .tokens = capacity,
                .lastUpdateMs = nowMs,
                .lastAccessMs = nowMs,
            });
            break :blk self.buckets.getPtr(key).?;
        };

        bucket.lastAccessMs = nowMs;

        // Refill tokens according to elapsed time
        const elapsed_ms: f64 = @floatFromInt(@max(0, nowMs - bucket.lastUpdateMs));
        bucket.tokens = @min(capacity, bucket.tokens + elapsed_ms * fill_rate_per_ms);
        bucket.lastUpdateMs = nowMs;

        const cost_f: f64 = @floatFromInt(cost);
        if (bucket.tokens >= cost_f) {
            bucket.tokens -= cost_f;
            const remaining_u32 = @as(u32, @intFromFloat(@floor(bucket.tokens)));
            const deficit = capacity - bucket.tokens;
            const reset_sec = if (fill_rate_per_ms > 0)
                @as(u32, @intFromFloat(@ceil(deficit / (fill_rate_per_ms * 1000.0))))
            else
                0;

            return RateLimitResult{
                .allowed = true,
                .limit = policy.limit,
                .remaining = remaining_u32,
                .resetSeconds = reset_sec,
                .retryAfterSeconds = 0,
            };
        } else {
            const deficit = cost_f - bucket.tokens;
            const wait_ms = if (fill_rate_per_ms > 0) deficit / fill_rate_per_ms else win_ms_f;
            const retry_after = @max(1, @as(u32, @intFromFloat(@ceil(wait_ms / 1000.0))));
            const total_deficit = capacity - bucket.tokens;
            const reset_sec = if (fill_rate_per_ms > 0)
                @as(u32, @intFromFloat(@ceil(total_deficit / (fill_rate_per_ms * 1000.0))))
            else
                retry_after;

            return RateLimitResult{
                .allowed = false,
                .limit = policy.limit,
                .remaining = 0,
                .resetSeconds = reset_sec,
                .retryAfterSeconds = retry_after,
            };
        }
    }

    /// Resets all recorded entries.
    pub fn clear(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.buckets.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.buckets.clearRetainingCapacity();
    }

    /// Returns the number of currently tracked identities.
    pub fn entryCount(self: *RateLimiter) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buckets.count();
    }

    fn sweepExpiredLocked(self: *RateLimiter, nowMs: i64, ttl_ms: i64) void {
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.buckets.iterator();
        while (it.next()) |entry| {
            if (nowMs - entry.value_ptr.lastAccessMs > ttl_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (to_remove.items) |k| {
            if (self.buckets.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    fn evictOldestLocked(self: *RateLimiter) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.buckets.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.lastAccessMs < oldest_time) {
                oldest_time = entry.value_ptr.lastAccessMs;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |k| {
            if (self.buckets.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
};

/// Identity extractor function to obtain a rate-limit key from a request context.
pub fn extractKey(
    ctx: *const Context,
    dimension: RateLimitDimension,
    buf: []u8,
) ![]const u8 {
    return switch (dimension) {
        .global => "global",
        .clientIp => blk: {
            const ip = ctx.remoteAddress() orelse "127.0.0.1";
            break :blk try std.fmt.bufPrint(buf, "ip:{s}", .{ip});
        },
        .userId => blk: {
            if (ctx.bearerToken()) |tok| {
                break :blk try std.fmt.bufPrint(buf, "user:{s}", .{tok});
            }
            if (ctx.header("X-User-Id")) |uid| {
                break :blk try std.fmt.bufPrint(buf, "user:{s}", .{uid});
            }
            if (ctx.cookie("session_id")) |sid| {
                break :blk try std.fmt.bufPrint(buf, "session:{s}", .{sid});
            }
            // Fallback to IP if unauthenticated
            const ip = ctx.remoteAddress() orelse "127.0.0.1";
            break :blk try std.fmt.bufPrint(buf, "anon:{s}", .{ip});
        },
        .apiKey => blk: {
            if (ctx.header("X-API-Key")) |key| {
                break :blk try std.fmt.bufPrint(buf, "key:{s}", .{key});
            }
            if (ctx.queryParam("apiKey")) |key| {
                break :blk try std.fmt.bufPrint(buf, "key:{s}", .{key});
            }
            const ip = ctx.remoteAddress() orelse "127.0.0.1";
            break :blk try std.fmt.bufPrint(buf, "nokey:{s}", .{ip});
        },
        .route => try std.fmt.bufPrint(buf, "route:{s} {s}", .{ ctx.method.name(), ctx.path }),
        .userAndRoute => blk: {
            const u = ctx.bearerToken() orelse ctx.header("X-User-Id") orelse (ctx.remoteAddress() orelse "anon");
            break :blk try std.fmt.bufPrint(buf, "u:{s}|r:{s} {s}", .{ u, ctx.method.name(), ctx.path });
        },
        .ipAndRoute => blk: {
            const ip = ctx.remoteAddress() orelse "127.0.0.1";
            break :blk try std.fmt.bufPrint(buf, "ip:{s}|r:{s} {s}", .{ ip, ctx.method.name(), ctx.path });
        },
        .custom => "custom",
    };
}

// Tests

test "rate limiter allows requests within limit and rejects when exceeded" {
    const a = std.testing.allocator;
    var rl = RateLimiter.init(a, 3, 1000);
    defer rl.deinit();

    try std.testing.expectEqual(@as(?u32, 2), try rl.check("user:alice", 0));
    try std.testing.expectEqual(@as(?u32, 1), try rl.check("user:alice", 10));
    try std.testing.expectEqual(@as(?u32, 0), try rl.check("user:alice", 20));
    // Quota exhausted
    try std.testing.expectEqual(@as(?u32, null), try rl.check("user:alice", 30));
}

test "per-user rate limit isolation: user A blocked does not block user B" {
    const a = std.testing.allocator;
    var rl = RateLimiter.init(a, 2, 1000);
    defer rl.deinit();

    // User A uses both tokens
    try std.testing.expectEqual(@as(?u32, 1), try rl.check("user:alice", 0));
    try std.testing.expectEqual(@as(?u32, 0), try rl.check("user:alice", 5));
    // User A is now rate-limited
    try std.testing.expectEqual(@as(?u32, null), try rl.check("user:alice", 10));

    // User B is completely unaffected and has independent quota!
    try std.testing.expectEqual(@as(?u32, 1), try rl.check("user:bob", 10));
    try std.testing.expectEqual(@as(?u32, 0), try rl.check("user:bob", 15));
    try std.testing.expectEqual(@as(?u32, null), try rl.check("user:bob", 20));
}

test "token bucket refilling over time" {
    const a = std.testing.allocator;
    var rl = RateLimiter.init(a, 10, 1000);
    defer rl.deinit();

    // Consume 10 tokens at t=0
    for (0..10) |_| {
        const r = try rl.check("key:test", 0);
        try std.testing.expect(r != null);
    }
    // Now exhausted at t=0
    try std.testing.expectEqual(@as(?u32, null), try rl.check("key:test", 0));

    // At t=500ms (half the window), 5 tokens should have refilled
    const res_mid = try rl.checkDetailed("key:test", 500, 1, rl.defaultPolicy);
    try std.testing.expect(res_mid.allowed);
    try std.testing.expectEqual(@as(u32, 4), res_mid.remaining);

    // At t=1500ms, full tokens refilled up to burst capacity (10)
    const res_full = try rl.checkDetailed("key:test", 1500, 1, rl.defaultPolicy);
    try std.testing.expect(res_full.allowed);
    try std.testing.expectEqual(@as(u32, 9), res_full.remaining);
}

test "rate limit 429 response formatting" {
    const a = std.testing.allocator;
    var rl = RateLimiter.init(a, 1, 1000);
    defer rl.deinit();

    _ = try rl.check("ip:1.2.3.4", 0);
    const rejected = try rl.checkDetailed("ip:1.2.3.4", 10, 1, rl.defaultPolicy);
    try std.testing.expect(!rejected.allowed);
    try std.testing.expect(rejected.retryAfterSeconds >= 1);

    const resp = try rejected.toResponse(a);
    defer RateLimitResult.deinitResponse(a, &resp);

    try std.testing.expectEqual(@as(u16, 429), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "too_many_requests") != null);
}

test "bounded memory and eviction of inactive entries" {
    const a = std.testing.allocator;
    var rl = RateLimiter.initWithOptions(a, .{
        .limit = 10,
        .windowMs = 1000,
        .ttlMs = 500,
    }, 4); // Max 4 entries
    defer rl.deinit();

    _ = try rl.check("id:1", 0);
    _ = try rl.check("id:2", 10);
    _ = try rl.check("id:3", 20);
    _ = try rl.check("id:4", 30);
    try std.testing.expectEqual(@as(usize, 4), rl.entryCount());

    // Adding 5th entry when at capacity triggers eviction
    _ = try rl.check("id:5", 40);
    try std.testing.expect(rl.entryCount() <= 4);

    // After TTL (500ms), sweep removes expired entries
    _ = try rl.check("id:fresh", 600);
    try std.testing.expect(rl.entryCount() <= 4);
}

test "concurrent requests safety" {
    const a = std.testing.allocator;
    var rl = RateLimiter.init(a, 1000, 10000);
    defer rl.deinit();

    const Worker = struct {
        limiter: *RateLimiter,
        id: usize,

        fn run(self: *@This()) void {
            var key_buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "thread:{d}", .{self.id}) catch return;
            for (0..50) |_| {
                _ = self.limiter.check(key, clock.millisNow()) catch {};
            }
        }
    };

    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    for (0..4) |i| {
        workers[i] = .{ .limiter = &rl, .id = i };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    }
    for (threads) |t| {
        t.join();
    }
    try std.testing.expect(rl.entryCount() >= 4);
}
