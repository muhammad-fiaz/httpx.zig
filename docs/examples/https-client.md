# HTTPS Client

TLS client requests through the high-level client, plus local TLS listener
setup. See `examples/https_client.zig` (listener init + config verification)
and `examples/tls_get.zig`.

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
var listener = try httpx.tls.Listener.init(allocator, io, .{
    .port = 0,
    .defaultIdentity = .{
        .certChainPem = cert,
        .privateKeyPem = key,
    },
});
defer listener.deinit();
```

## Run

```bash
zig build run-https-client
```

## Checklist

- [x] TLS listener initializes with an identity and reports its port
- [x] External HTTPS GET returns 200 (network permitting)
