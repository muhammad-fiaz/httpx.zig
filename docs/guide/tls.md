# TLS Configuration Guide

HTTPX implements modern Transport Layer Security (TLS 1.2 and TLS 1.3) with full cross-platform support across Linux, Windows, and macOS.

## Client HTTPS Usage

HTTPS works out of the box with zero configuration:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

// Automatically performs TLS 1.3 handshake with SNI and ALPN
const response = try client.get("https://cloudflare.com", .{});
defer response.deinit();
```

### Custom CA Bundles & Self-Signed Certs
For local development or internal PKI:
```zig
const response = try client.get("https://internal.corp", .{
    .tls = .{
        .verify = .selfSigned, // Accept self-signed certificates
        .allowTruncation = true,
    },
});
defer response.deinit();
```

---

## Server TLS Configuration

HTTPX provides first-class native TLS/HTTPS support directly integrated into `httpx.Server`.

To launch a secure HTTPS server, supply PEM-encoded certificate chain and private key (either as in-memory PEM string or as file path):

```zig
const certPem = @embedFile("certs/server.crt");
const keyPem = @embedFile("certs/server.key");

var server = try httpx.Server.init(allocator, io, .{
    .port = 8443,
    .tls = .{
        .certPem = certPem,
        .keyPem = keyPem,
        .allowPlainHttp = false, // strict HTTPS mode (default)
    },
});
defer server.deinit();

try server.get("/", helloHandler);

server.run();
```

Handlers can inspect the connection's encryption status via `Context`
(`ctx.isTls`, `ctx.scheme()`), as in `helloHandler` below:

```zig
fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.isTls) return ctx.text("Hello HTTPS!");
    return ctx.text("Hello HTTP!");
}
```

### Dynamic TLS Reconfiguration

You can inspect and reconfigure TLS at runtime without stopping the server:

```zig
// Check if TLS is currently active
if (server.isTls()) {
    std.debug.print("Server running in HTTPS mode\n", .{});
}

// Dynamically rotate or enable certificates and keys
try server.setTls("certs/new_cert.pem", "certs/new_key.pem");
```

When rotating or deinitializing certificates, private key memory in heap buffers is automatically zeroed using `std.crypto.secureZero` before release.

### Handshake Detection & Strict HTTPS Rejection

When TLS is active on the server port, HTTPX peeks at the initial connection bytes:
* If the bytes start with the TLS record header (`0x16 0x03`), HTTPX executes the TLS server handshake.
* If a plain HTTP request (e.g. `GET / HTTP/1.1`) arrives on an HTTPS port and `allowPlainHttp` is `false` (the default), HTTPX immediately rejects the connection with:
  ```http
  HTTP/1.1 400 Bad Request
  Content-Type: text/plain
  Connection: close

  The plain HTTP request was sent to HTTPS port
  ```
* If `allowPlainHttp = true`, HTTPX seamlessly routes cleartext HTTP requests on the same port (dual HTTP/HTTPS mode, ideal for local testing).

### ALPN Protocol Negotiation

During the TLS handshake, HTTPX negotiates the application protocol via ALPN:
1. `h2`: Dispatched to HTTP/2 binary multiplexed connection handler.
2. `http/1.1`: Dispatched to HTTP/1.1 connection pipeline.

### Connection Security & Context

Handlers can inspect the connection's encryption status via `Context`:
* `ctx.isTls`: `bool` indicating whether the request was received over TLS.
* `ctx.scheme()`: Returns `"https"` for TLS connections (or if trusted `X-Forwarded-Proto` indicates HTTPS).

### Structured Event Logging

When a client fails TLS handshakes (malformed ClientHello, unsupported ciphers, or aborted handshake), HTTPX emits a structured non-allocating event:
* `event.kind == .tlsHandshakeFailed`
This allows application observability without emitting unauthorized stdout/stderr noise.

## Error Taxonomy

When certificate verification or handshake fails, HTTPX returns precise error types:
* `error.CertificateExpired`: Certificate validity window has passed.
* `error.CertificateHostMismatch`: Certificate SAN/CN does not match requested host.
* `error.CertificateIssuerMismatch`: Intermediate CA signature could not be verified.
* `error.TlsCertificateNotVerified`: Certificate not trusted by root CA store.
* `error.TlsHandshakeFailed`: General TLS protocol or alert failure.

## Related

* [API: TLS](/api/tls)
* [Protocol: TLS 1.2](/protocols/tls-1.2)
* [Protocol: TLS 1.3](/protocols/tls-1.3)
* [Security: TLS](/security/tls)
