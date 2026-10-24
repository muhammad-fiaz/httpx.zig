# Rate Limiting & DoS Protection

Uncontrolled request rates can exhaust server memory, thread pools, and backend database connections. HTTPX implements thread-safe token bucket rate limiters.

## Algorithm & Keying

```text
Incoming Request -> Key Extractor (Remote IP, API Key, User ID)
                    |
                    v
             Bucket State (Tokens, Last Refill)
                    |
             Has >= 1 token?
             |            |
            Yes           No
             |            |
         Consume 1     Return 429 Too Many Requests
         Proceed       Inject Retry-After: <seconds>
```

## Implementation

```zig
// 50 requests per 60s window.
var limiter = httpx.RateLimiter.init(allocator, io, .{
    .policy = .{ .limit = 50, .windowMs = 60_000 },
});
defer limiter.deinit();

const RateGate = struct {
    var rl: ?*httpx.RateLimiter = null;

    fn middleware(ctx: *httpx.web.router.Context, next: httpx.web.router.NextFn) anyerror!httpx.web.router.Response {
        const now = httpx.clock.monotonicMillis(ctx.io);
        var keyBuf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&keyBuf, "ip:{s}", .{ctx.remoteAddress() orelse "unknown"});
        const remaining = try rl.?.check(key, now);
        if (remaining == null) {
            return ctx.textStatus(429, "Rate limit exceeded");
        }
        return next(ctx);
    }
};
RateGate.rl = &limiter;
try server.use(RateGate.middleware);
```

## Related

* [Guide: Rate Limiting](/guide/rate-limiting)
* [Example: Rate Limit Server](/examples/rate-limit-server)
