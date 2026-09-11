# TLS Configuration Guide

HTTPX implements Transport Layer Security with full cross-platform support
across Linux, Windows, and macOS.

## Support Scope (read this first)

* **Client** (`httpx.Client` → `https://`): HTTPS/1.1 without client
  certificates runs on `std.crypto.tls` (TLS 1.2/1.3) with SNI, system +
  custom trust stores, and hostname verification. Setting
  `.tls = .{ .clientCertPem, .clientKeyPem }` (mTLS) or explicit
  `.httpVersion = .http2` switches that request to the **native** client
  instead, adding certificate presentation and/or ALPN (`h2` for HTTP/2,
  `http/1.1` otherwise) on top of the same verification.
* **Server** (native engine in `src/protocols/tls/`): **TLS 1.3 only**, with
  X25519 ECDHE, AES-128-GCM / AES-256-GCM / ChaCha20-Poly1305 record
  protection, SNI parsing, and ALPN dispatch. Server certificates must be
  **P-256 ECDSA** (`ecdsa_secp256r1_sha256`); RSA/private-key types are
  rejected loudly with `UnsupportedSignatureScheme` instead of emitting a
  broken handshake.
* **Session resumption** (TLS 1.3 PSK, `psk_dhe_ke`): the native client
  offers cached sessions and the native server issues stateless tickets —
  see [Session Resumption](#session-resumption-psk--tickets) below.
  Resumption covers the native paths (HTTP/2 over TLS always; HTTPS/1.1
  when already native via client certificates). Plain HTTPS/1.1 runs on
  `std.crypto.tls`, which exposes no ticket API, so it always does full
  handshakes.
* **HelloRetryRequest**: fully handled on both sides (shareless hello →
  retry with share, single-retry guard, transcript splice). Only X25519
  is supported: a server selecting any other group fails loudly.
* **Not implemented, by policy**: 0-RTT early data. There is deliberately
  **no** 0-RTT at any layer (replay-unsafe methods must never be sent
  early); tickets never carry `early_data` extensions.

## Mutual TLS (Client Certificates)

The server can require (or optionally accept) client certificates:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .tls = .{
        .certPem = cert_pem,
        .keyPem = key_pem,
        .clientAuth = .required, // or .optional / .disabled (default)
        .clientCa = ca_pem,      // PEM bundle trusted for client chains
    },
});
```

With `.required`, a missing certificate fails the handshake: the client
observes `error.ClientCertificateRequired` (its native handshake refuses
to continue cert-less) while the server side only ever sees the
connection vanish mid-flight (`error.IoError` / `error.TlsHandshakeFailed`)
— there is no server-side policy error to assert on. Presented chains
must anchor in `clientCa` with valid signatures
(`error.ClientCertificateInvalid` otherwise). `.optional` lets cert-less
clients through while still verifying any presented chain. See
`[TLS mTLS](/examples/tls-mtls)` for a runnable loopback demo.

A client presents its certificate through the high-level API — no
engine calls needed:

```zig
var res = try client.get("https://service.internal/", .{
    .tls = .{
        .verify = .caBundle,
        .caPem = ca_pem, // extra trust anchor for the server chain
        .clientCertPem = cert_pem, // presented when requested
        .clientKeyPem = key_pem,   // P-256 ECDSA key for the chain
    },
});
defer res.deinit();
```

Omitting the pair on a `.required` server fails the request loudly;
a non-`http/1.1` ALPN answer on the HTTP/1.x path (and anything but
`h2` on the `.http2` path) fails with `error.AlpnNegotiationFailed`
instead of silently downgrading.

## Session Resumption (PSK / Tickets)

TLS 1.3 resumption (RFC 8446 Sections 4.6.1, 4.2.11) abbreviates repeat
handshakes: no Certificate/CertificateVerify flight, authentication via
the PSK binder, forward secrecy preserved (`psk_dhe_ke` always performs
fresh ECDHE alongside the PSK).

Server — opt in with ticket keys (stateless; no per-client storage):

```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8443,
    .tls = .{
        .certPem = cert_pem,
        .keyPem = key_pem,
        .ticketKeys = httpx.tls.TicketKeys.generate(),
        .ticketLifetimeSecs = 7200,
    },
});
```

Rotate with `keys.rotate(next)`; outstanding tickets stay valid through
one rotation via the previous-key slot, then fail closed (clients fall
back to full handshakes — never an alert storm).

Client — automatic on the native paths: `httpx.Client` keeps an
origin-keyed session cache, offers usable tickets, captures new ones
from `NewSessionTicket` messages during reads, and resumes
transparently. No API changes needed.

Rules that keep resumption honest:

- Any ticket problem (unknown/expired/corrupt ticket, binder mismatch,
  suite mismatch) silently falls back to a full handshake — the client
  cannot distinguish either way.
- Resumption is disabled under mutual TLS: an abbreviated flight carries
  no `CertificateRequest`, so resumed connections would bypass client
  certificate authentication. Servers with `clientAuth` set always do
  full handshakes.
- Only SHA-256 suites resume (`AES_128_GCM_SHA256`,
  `CHACHA20_POLY1305_SHA256`); tickets for other hashes are ignored.
- Tickets bind to the issuing origin host; the client never offers a
  ticket to a different host.

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
