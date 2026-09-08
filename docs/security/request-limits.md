# Request Limits & DoS Hardening

Prevent denial-of-service (DoS) attacks by enforcing strict limits on request sizes, header counts, and execution timeouts.

## Configurable Limits

```zig
var server = try httpx.Server.init(allocator, io, .{
    .max_header_size = 16 * 1024,         // 16 KB header limit
    .max_headers = 100,                   // 100 headers maximum
    .max_body_size = 10 * 1024 * 1024,    // 10 MB body payload limit
    .read_timeout_ms = 10_000,            // 10s read deadline
    .write_timeout_ms = 10_000,           // 10s write deadline
});
defer server.deinit();
```

| Limit | Default | Purpose |
|---|---|---|
| `max_header_size` | `32 KB` | Prevents memory exhaustion from oversized headers |
| `max_headers` | `100` | Limits computational complexity during header parsing |
| `max_body_size` | `64 MB` | Rejects oversized payloads with `413 Payload Too Large` |
| `read_timeout_ms` | `30000` | Mitigates Slowloris attacks by terminating slow connections |
| `write_timeout_ms` | `30000` | Reclaims sockets stalled on outgoing writes |

## Slowloris Attack Mitigation

Slowloris attacks send partial HTTP request headers at extremely slow rates (e.g. 1 byte every 10 seconds), exhausting the server's connection pool. HTTPX enforces strict `read_timeout_ms` across header reception, closing sockets that fail to deliver a complete header block within the deadline.

## Related

* [Security: Overview](/security/overview)
* [Security: Rate Limiting](/security/rate-limiting)
