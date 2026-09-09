# Rate Limiting Guide

HTTPX provides token-bucket rate limiting via `httpx.RateLimiter` to protect
servers from abuse, brute-force attempts, and denial of service attacks.

## Token Bucket Algorithm

```zig
const std = @import("std");
const httpx = @import("httpx");

fn limitedHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "ok", .data = "sensitive information" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // 10 requests per 60s window, burst up to 10.
    var limiter = httpx.RateLimiter.init(allocator, 10, 60_000);
    defer limiter.deinit();

    try server.get("/api/data", limitedHandler);

    server.run();
}
```

Gate per request with `check(key, nowMs)` (remaining quota, or `null` when
limited) or `checkDetailed` for full `RateLimitResult` metadata
(`allowed`, `remaining`, `resetSeconds`, `retryAfterSeconds`). Build keys by
dimension (`RateLimitDimension`: `.global`, `.clientIp`, `.userId`,
`.apiKey`, `.route`, `.userAndRoute`, `.ipAndRoute`, `.custom`).

Configure windows with `RateLimitPolicy` (`.limit`, `.windowMs`, `.burst`,
`.ttlMs`) via `initWithOptions`.

## Rate Limiting Headers

`RateLimitResult.toResponse(allocator)` renders a `429` response with standard
headers:

* `X-RateLimit-Limit`: Maximum bucket capacity.
* `X-RateLimit-Remaining`: Tokens remaining in the current window.
* `X-RateLimit-Reset`: Seconds until bucket is fully replenished.
* `Retry-After`: Seconds to wait before retrying (on 429 responses).

## Related

* [Security: Rate Limiting](/security/rate-limiting)
* [Security: Request Limits](/security/request-limits)
