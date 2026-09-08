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
var limiter = httpx.web.rate_limit.RateLimiter.init(allocator, .{
    .capacity = 50,      // Allow burst of 50 requests
    .refill_rate = 5.0,  // Refill 5 requests per second
});
defer limiter.deinit();

server.use(struct {
    fn rateLimitMiddleware(ctx: *httpx.Context) !void {
        const key = ctx.remoteIp() orelse "unknown";
        if (!limiter.allow(key)) {
            ctx.status(429);
            ctx.header("Retry-After", "2");
            try ctx.json(.{ .error = "Rate limit exceeded" });
            return;
        }
        try ctx.next();
    }
}.rateLimitMiddleware);
```

## Related

* [Guide: Rate Limiting](/guide/rate-limiting)
* [Example: Rate Limit Server](/examples/rate-limit-server)
