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
| `limits.maxActive` | `128` | Caps active and queued connection tasks |
| `limits.maxQueued` | `128` | Bounds pending work; new connections are closed when full |
| `timeouts.initialRequest` | `5000` | Bounds the wait for initial request bytes |
| `timeouts.headerRead` | `10000` | Absolute deadline to finish request headers |
| `timeouts.requestBody` | `30000` | Absolute deadline to receive the complete body |
| `timeouts.write` | `30000` | Absolute response write deadline |
| `timeouts.keepAliveIdle` | `30000` | Bounds idle keep-alive reads |

Pair with `httpx.RateLimiter` middleware for per-IP request-rate enforcement.

## Slowloris Attack Mitigation

The server processes connections through a bounded worker pool, so a client waiting before sending data does not block the accept loop or unrelated workers. `limits.maxActive` bounds active plus queued connections, and a full limit closes newly accepted sockets. The initial-byte, header, body, write, and keep-alive settings in the inline options passed to `httpx.Server.init` use absolute phase deadlines; sending occasional bytes does not extend the header or body deadline. Set these deadlines to finite values for exposed services. Setting one to zero disables that deadline and can let a stalled peer occupy a worker until another limit or shutdown intervenes. A handler that blocks in application code is not forcibly cancelled. A reverse proxy or load balancer can add another independent resource boundary, but does not replace server-side limits.

## Related

* [Security: Overview](/security/overview)
* [Security: Rate Limiting](/security/rate-limiting)
