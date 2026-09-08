# Rate Limiting Guide

HTTPX provides token-bucket rate limiting middleware to protect servers from abuse, brute-force attempts, and denial of service attacks.

## Token Bucket Algorithm

The token bucket allows bursts of requests up to a configurable bucket capacity, while steadily refilling tokens at a fixed rate per second.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // Rate limiter: 10 requests burst, refilling at 2 requests per second
    var limiter = httpx.web.rate_limit.RateLimiter.init(allocator, .{
        .capacity = 10,
        .refill_rate = 2.0,
    });
    defer limiter.deinit();

    server.get("/api/data", struct {
        fn handle(ctx: *httpx.Context) !void {
            const ip = ctx.remoteIp() orelse "127.0.0.1";
            if (!limiter.allow(ip)) {
                ctx.status(429);
                ctx.header("Retry-After", "5");
                try ctx.json(.{ .error = "Too Many Requests" });
                return;
            }

            try ctx.json(.{ .status = "ok", .data = "sensitive information" });
        }
    }.handle);

    try server.run();
}
```

## Rate Limiting Headers

Standard HTTP headers returned when rate limits are active:
* `X-RateLimit-Limit`: Maximum bucket capacity.
* `X-RateLimit-Remaining`: Tokens remaining in the current window.
* `X-RateLimit-Reset`: Seconds until bucket is fully replenished.
* `Retry-After`: Seconds to wait before retrying (on 429 responses).

## Related

* [Security: Rate Limiting](/security/rate-limiting)
* [Security: Request Limits](/security/request-limits)
