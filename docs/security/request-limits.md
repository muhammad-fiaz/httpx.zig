# Request Limits & DoS Hardening

Prevent denial-of-service (DoS) attacks by enforcing strict limits on request sizes and connection counts.

## Configurable Limits

```zig
var server = try httpx.Server.init(allocator, io, .{
    .maxBody = 10 * 1024 * 1024, // 10 MB body payload limit
    .maxRequestsPerConn = 1000,  // cap requests per keep-alive connection
});
defer server.deinit();
```

| Limit | Default | Purpose |
|---|---|---|
| `maxBody` | `8 MB` | Rejects oversized payloads |
| `maxRequestsPerConn` | `1000` | Bounds keep-alive reuse per connection |

Pair with `httpx.RateLimiter` middleware for per-IP request-rate enforcement.

## Slowloris Attack Mitigation

Slowloris attacks send partial HTTP request headers at extremely slow rates (e.g. 1 byte every 10 seconds), exhausting the server's connection pool. Mitigate by capping `maxConnections`, pairing with a reverse proxy or LB idle timeout, and monitoring `server.snapshot()` error and connection counters.

## Related

* [Security: Overview](/security/overview)
* [Security: Rate Limiting](/security/rate-limiting)
