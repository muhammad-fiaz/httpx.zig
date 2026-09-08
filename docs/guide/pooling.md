# Connection Pooling Guide

HTTPX includes an internal, thread-safe connection pool designed for high throughput, connection reuse, and minimal socket creation overhead.

## Architecture

```text
HTTP Request -> Pool.acquire(host, port)
                 |
                 +--> Reusable Keep-Alive socket found?
                 |       Yes: Send request on existing socket
                 |       No: Connect new TCP/TLS socket
                 |
HTTP Response -> Pool.release(socket)
                 |
                 +--> Return to idle pool for subsequent requests
```

## Configuration

Connection pooling is configured on `Client.init`:

```zig
var client = httpx.Client.init(allocator, io, .{
    .max_connections = 64,
    .max_idle_connections = 16,
    .idle_timeout_ms = 30_000,
});
defer client.deinit();
```

| Option | Type | Default | Description |
|---|---|---|---|
| `max_connections` | `usize` | `128` | Total active connections across all hosts |
| `max_idle_connections` | `usize` | `32` | Max idle sockets preserved in pool |
| `idle_timeout_ms` | `u32` | `60000` | Sockets idle longer than this are closed |

## Pool Key Isolation

Connections are keyed by:
1. Target Hostname / IP
2. Target Port
3. Transport Scheme (`http` vs `https`)
4. Proxy Configuration (direct vs proxy endpoint)

A connection established for `http://example.com` will never be mistakenly reused for `https://example.com` or through a proxy.

## Related

* [API: Pool](/api/pool)
* [Example: Connection Pool](/examples/connection-pool)
