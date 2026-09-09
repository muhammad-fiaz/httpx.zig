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
    .pool = .{
        .maxConnections = 64,
        .maxPerHost = 16,
        .idleTimeoutMs = 30_000,
    },
});
defer client.deinit();
```

| Option | Type | Default | Description |
|---|---|---|---|
| `maxConnections` | `u32` | `256` | Hard ceiling across all origins |
| `maxPerHost` | `u16` | `16` | Ceiling per origin (host + port) |
| `idleTimeoutMs` | `i64` | `30000` | Parked sockets older than this are dropped |
| `maxParkedMs` | `i64` | `300000` | Max time a connection may stay parked (`0` disables) |

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
