# TLS HTTPS GET

Local HTTPS server setup with a self-signed identity. See
`examples/tlsGet.zig` (`run-tls-get`) and `examples/httpsClient.zig`
(`run-https-client`).

## Covers

- TLS server with self-signed certificates
- Server lifecycle (init, local port, routes)

## Example

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .enableDocs = false,
    .tls = .{
        .certificatePem = certPem,
        .privateKeyPem = keyPem,
    },
});
defer server.deinit();

const port = server.localPort();
```

## Expected Output

```text
TLS listening on 54321
HTTPS status: 200
```

The ephemeral loopback port varies per run; certificate material varies by deployment. Loopback only with a self-signed identity (`examples/tlsGet.zig` via `run-tls-get`, `examples/httpsClient.zig` via `run-https-client`), no external service required for the local listener. External `https://example.com/` fetch requires network access and system CA trust.

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
