# HTTPS Client

TLS client requests through the high-level client, plus local TLS listener
setup. See `examples/httpsClient.zig` (listener init + config verification)
and `examples/tlsGet.zig`.

```zig
// External HTTPS through the client (zero config).
var res = try client.get("https://example.com/", .{});
defer res.deinit();

// Development only: bypass verification for self-signed endpoints.
var dev = try client.get("https://127.0.0.1:8443/", .{
    .tls = .{ .verify = .none },
});
defer dev.deinit();
```

Local listener setup with an identity:

```zig
var listener = try httpx.protocols.tls.Listener.init(allocator, io, .{
    .port = 0,
    .defaultIdentity = .{
        .certChainPem = cert,
        .privateKeyPem = key,
    },
});
defer listener.deinit();
```

## Expected Output

```text
TLS listener initialized on port 54321, config verified
```

Port varies per run (ephemeral port); external `client.get("https://example.com/")` returns 200 when network permits.

## Run

```bash
zig build run-https-client
```

## Checklist

- [x] TLS listener initializes with an identity and reports its port
- [x] External HTTPS GET returns 200 (network permitting)
