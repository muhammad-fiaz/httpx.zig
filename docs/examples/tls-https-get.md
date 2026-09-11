# TLS HTTPS GET

Local TLS listener setup with a self-signed identity. See
`examples/tls_get.zig` (`run-tls-get`) and `examples/https_client.zig`
(`run-https-client`).

## Features Demonstrated

- TLS server with self-signed certificates
- Listener lifecycle (init, local port, config verification)

## Demo Program

```zig
var listener = try httpx.tls.Listener.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .defaultIdentity = .{
        .certChainPem = cert_pem,
        .privateKeyPem = key_pem,
    },
});
defer listener.deinit();

const port = listener.localPort();
std.debug.print("TLS listening on {d}\n", .{port});
```

## Run

```bash
zig build run-tls-get
```

## End-to-End Traffic

For full request/response verification over local TLS, see:

- `[TLS mTLS](/examples/tls-mtls)` — mutual-TLS HTTP (`run-tls-mtls`):
  trusted client served, cert-less client rejected.
- `[HTTP/2 over TLS](/examples/http2-example)` — ALPN `h2` with chain
  verification (`run-http2-tls`).
- External HTTPS endpoints work via the high-level client:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var res = try client.get("https://example.com/", .{});
defer res.deinit();
std.debug.print("HTTPS status: {d}\n", .{res.status});
```

## What to Verify

- Listener binds an ephemeral port and reports it via `localPort()`.
- Configuration verifies without handshake errors.
