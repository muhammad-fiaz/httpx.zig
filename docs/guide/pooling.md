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

Plain-TCP keep-alive connections are keyed by target host and port. HTTP/2
sessions add a TLS/h2c discriminator, so TLS and cleartext sessions never share
a lane. HTTP/3 sessions are keyed by host, port, and TLS policy fingerprint.

The high-level client hands out pooled HTTP/2 and HTTP/3 connections
exclusively, so sequential requests reuse a connection while concurrent
requests use separate connections rather than sharing one.

## Related

* [API: Pool](/api/pool)
* [Example: Connection Pool](/examples/connection-pool)
