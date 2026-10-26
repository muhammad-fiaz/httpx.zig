# TLS API

The TLS layer combines a native TLS 1.3 implementation (server engine +
client, handshake/record/ALPN/certificate code built on `std.crypto`
primitives) with the `std.crypto.tls` wrapper for plain HTTPS/1.1 client
requests. No C/OpenSSL FFI anywhere.

::: warning Custom Implementation
Zig's standard library exposes no ALPN hook, so **httpx.zig implements
its own TLS 1.3 handshake paths**, including:
- **TLS 1.3** native server engine + native client (RFC 8446); TLS 1.2
  remains available through the std-based HTTPS/1.1 client transport
- **Key exchange:** X25519 (P-256 ECDSA certificates)
- **AEAD cipher suites:** ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM
- **ALPN negotiation** (RFC 7301): native on both sides, `h2` +
  `http/1.1` (+ `h3` for QUIC)
- **Handshake message encryption** (TLS 1.3)
- **X.509 certificate parsing and verification** (both sides)
- **Mutual TLS**: `CertificateRequest`, client chain + signature
  verification, required/optional policy
- **Custom record-layer encryption/decryption**
:::

## Supported Features

| Feature | TLS 1.2 (std transport) | TLS 1.3 (native) |
|---------|-------------------------|------------------|
| X25519 key exchange | ✅ | ✅ |
| AES-128-GCM | ✅ | ✅ |
| AES-256-GCM | ✅ | ✅ |
| ChaCha20-Poly1305 | ✅ | ✅ |
| ECDSA P-256 certificate signing | -- | ✅ |
| Certificate loading (PEM) | ✅ | ✅ |
| Certificate chain verification | ✅ | ✅ (both sides) |
| ALPN negotiation | -- | ✅ |
| SNI extension | ✅ | ✅ (DNS names) |
| Handshake message encryption | -- | ✅ |
| Cipher suite selection from client list | -- | ✅ |
| Mutual TLS enforcement | -- | ✅ |
| Post-handshake `KeyUpdate` | -- | Yes (both roles, RFC 9846 sender cap) |
| PSK resumption (`psk_dhe_ke` NST tickets) | -- | ✅ (native paths; std HTTPS/1.1 always full handshake) |
| HelloRetryRequest | -- | ✅ (both sides, single-retry guard) |
| 0-RTT early data | -- | ❌ intentionally unsupported (replay risk) |

## Architecture

```
tls.zig              -- Client/Server owners, Session, Certificate, TrustStore
├── client.zig       -- Client owner + native TLS client transport
├── server.zig       -- Server owner + native TLS server transport
├── engine.zig       -- (internal) TLS 1.3 handshake engine, key schedule
├── quicTls.zig      -- RFC 9001 key schedule for TLS-in-QUIC
├── transport.zig    -- (internal) std-based HTTPS/1.1 client transport
├── handshake.zig    -- handshake message encode/decode, transcript
├── record.zig       -- record-layer AEAD encrypt/decrypt
├── certificate.zig  -- X.509 parsing (+ structural DER guard)
├── verify.zig       -- chain/hostname verification
├── trustStore.zig  -- system + custom trust anchors
├── config.zig       -- shared enums (versions, client-auth modes)
├── alpn.zig         -- ALPN protocol negotiation
├── key.zig          -- private key parsing (zeroed after use)
└── errors.zig       -- Unified TLS error set and alert conversion
```

The public API is two owners — `httpx.protocols.tls.Client` and
`httpx.protocols.tls.Server` — plus value types (`Session`, `Certificate`,
`TrustStore`). The handshake engine, records, and transports are
implementation details selected internally per connection.

```zig
var tlsClient = try httpx.protocols.tls.Client.init(allocator, io, .{});
defer tlsClient.deinit();

var conn = try tlsClient.connect(&socket, "example.com", .{
    .verify = .caBundle,
});
defer conn.deinit();
```

```zig
var tlsServer = try httpx.protocols.tls.Server.init(allocator, io, .{
    .certificatePem = certPem,
    .privateKeyPem = keyPem,
});
defer tlsServer.deinit();

var conn = try tlsServer.accept(&socket);
defer conn.deinit();
```

## TlsConfig (Client)

Per-request and client-level TLS options (`src/client/request.zig`):

```zig
pub const TlsOptions = struct {
    verify: VerifyMode = .caBundle, // .caBundle, .selfSigned, .none
    caBundle: ?*std.crypto.Certificate.Bundle = null,
    caPem: ?[]const u8 = null, // custom CA PEM for the native paths
    clientCertPem: ?[]const u8 = null, // presented when the server asks (native paths)
    clientKeyPem: ?[]const u8 = null, // P-256 ECDSA key for clientCertPem
    allowTruncation: bool = true,
};
```

```zig
// Development-only verification bypass:
var res = try client.get("https://127.0.0.1:8443/", .{ .tls = .{ .verify = .none } });
```

Mutual TLS through the high-level API — setting the pair routes the
request through the native TLS 1.3 client (ALPN `http/1.1`, or `h2`
with `.httpVersion = .http2`):

```zig
var res = try client.get("https://127.0.0.1:8443/", .{
    .tls = .{
        .verify = .caBundle,
        .caPem = ca_pem,
        .clientCertPem = cert_pem,
        .clientKeyPem = key_pem,
    },
});
```

Explicit HTTP/2 over TLS uses the native client automatically (ALPN
`h2`, chain + hostname verification, `AlpnNegotiationFailed` when the
server selects anything else):

```zig
var res = try client.get("https://127.0.0.1:8443/", .{
    .httpVersion = .http2,
    .tls = .{ .verify = .caBundle, .caPem = ca_pem },
});
```

## ServerConfig

Server identity and ALPN preference (`tls.Server.Config`):

```zig
pub const Config = struct {
    certificatePem: ?[]const u8 = null, // PEM string or file path
    privateKeyPem: ?[]const u8 = null,  // PEM string or file path
    certSelector: ?CertSelector = null, // SNI selector, falls back to the default identity
    alpn: []const AlpnProtocol = &.{ .h2, .@"http/1.1" },
    clientAuth: ClientAuthMode = .disabled, // .disabled / .optional / .required
    clientCaPem: ?[]const u8 = null,        // CA bundle trusted for client chains
    ticketKeys: ?TicketKeys = null,         // stateless resumption keys
    ticketLifetimeSecs: u32 = 7200,
    allowPlainHttp: bool = false,
};
```

The identity is parsed and validated once at `Server.init` (fail fast
at startup); per-connection handshakes reuse it.

## Server Configuration

Enable TLS on the server via `ServerConfig.tls` (PEM string or file path for
both entries):

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.server.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8443,
    .tls = .{
        .certificatePem = @embedFile("cert.pem"),
        .privateKeyPem = @embedFile("key.pem"),
    },
    .http2 = true,
});
```

For a standalone TLS listener, use `httpx.protocols.tls.Listener`:

```zig
var listener = try httpx.protocols.tls.Listener.init(allocator, io, .{
    .port = 8443,
    .defaultIdentity = .{
        .certChainPem = @embedFile("cert.pem"),
        .privateKeyPem = @embedFile("key.pem"),
    },
});
defer listener.deinit();
try listener.run(handler);
```

::: tip ALPN Default
The server negotiates ALPN from `alpn` (default TCP preference: h2 then http/1.1), so clients negotiate HTTP/2 or HTTP/1.1 automatically.
:::

The server automatically loads the certificate chain and private key on the first TLS connection. ALPN negotiation selects between HTTP/1.1, HTTP/2, and HTTP/3 based on the client's offer.

## Connection

Client connections flow through the high-level client (`client.get("https://…")`),
which performs the handshake, ALPN negotiation, hostname verification, and
record-layer encryption internally. Server connections are accepted by
`httpx.protocols.tls.Listener` / `Server.tls` and dispatched to HTTP/1 or HTTP/2
handlers based on the negotiated ALPN protocol.

Post-handshake TLS 1.3 `KeyUpdate` records are handled transparently by
`read`: receive keys rotate, and a peer requesting an update is answered
automatically. Servers can initiate an update with
`conn.sendKeyUpdate(true)`; the new keys take effect immediately for
subsequent records.

### Methods (server side)

| Method | Description |
|--------|-------------|
| `httpx.protocols.tls.Client.init(allocator, io, .{})` | TLS client owner (trust parsed once) |
| `client.connect(&socket, host, .{})` | Handshake; returns an owned `Connection` |
| `conn.read/writeAll/deinit` | Record I/O and teardown (deinit closes the socket) |
| `conn.sendKeyUpdate(request_update)` | Rotate sending keys; request the peer to rotate its sending keys too |
| `conn.takeCapturedSession()` | Take a captured resumption session, if any |
| `httpx.protocols.tls.Server.init(allocator, io, cfg)` | TLS server owner (identity validated once) |
| `server.accept(&socket)` | Accept; returns an owned `Connection` |
| `server.acceptBuffered(&socket, peeked)` | Accept with pre-read bytes |
| `httpx.protocols.tls.Listener.init(allocator, io, cfg)` | Bind a TLS listener with `defaultIdentity` |
| `listener.run(handler)` | Blocking accept loop |
| `listener.stop()` | Immediate shutdown |
| `listener.localPort()` | Actual bound port |
| `server.setTls(certPemOrPath, keyPemOrPath)` | Rotate server identity at runtime |
| `server.isTls()` | Whether TLS is active |

## ALPN Negotiation

The ALPN module provides protocol negotiation between client and server:

```zig
// Protocol detection
try std.testing.expect(alpn.isHttp2("h2"));
try std.testing.expect(alpn.isHttp3("h3"));
try std.testing.expect(alpn.isHttp1x("http/1.1"));
```

## Certificate Verification

Certificate verification uses `std.crypto.Certificate.Chain` for chain validation and hostname verification. During the TLS handshake, the client:

1. Parses each DER certificate in the chain
2. Verifies signatures using the issuer's public key
3. Checks certificate validity periods
4. Verifies the hostname matches the certificate's Subject Alternative Names
5. Downloads root certificates from the configured CA bundle when needed

```zig
// During handshake, the certificate chain is verified automatically.
// Failures surface as client errors (e.g. TlsAlert) or server
// tls_handshake_failed events; see the error tables below.
```

### Certificate-Related Errors

| Error | Description |
|-------|-------------|
| `TlsCertificateExpired` | Certificate validity period has expired |
| `TlsCertificateNotYetValid` | Certificate validity period has not yet started |
| `TlsCertificateNotVerified` | Certificate chain was not verified (no trusted root found) |
| `TlsHostnameMismatch` | Hostname doesn't match certificate |
| `TlsBadCertificate` | Certificate is malformed or invalid |

## Types

### CipherSuite

Supported cipher suites:

| Suite | TLS Version | Notes |
|-------|-------------|-------|
| `AES_128_GCM_SHA256` | 1.3 | Default |
| `AES_256_GCM_SHA384` | 1.3 | |
| `CHACHA20_POLY1305_SHA256` | 1.3 | |
| `ECDHE_RSA_WITH_AES_128_GCM_SHA256` | 1.2 | |
| `ECDHE_RSA_WITH_AES_256_GCM_SHA384` | 1.2 | |
| `ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256` | 1.2 | |

### Named Groups

Supported elliptic curves for key exchange:

| Group | Notes |
|-------|-------|
| `x25519` | Default, only key exchange actually negotiated by both client and server |

### Error Set

All TLS errors are unified in `TlsError`:

| Error | Description |
|-------|-------------|
| `TlsCloseNotify` | Clean shutdown |
| `TlsBadRecordMac` | AEAD authentication failed |
| `TlsCertificateExpired` | Certificate validity expired |
| `TlsHostnameMismatch` | Hostname doesn't match certificate |
| `TlsHandshakeFailure` | No acceptable parameters negotiated |
| `TlsUnsupportedCipherSuite` | Unsupported cipher suite |

**PEM Loading Errors** (returned by `loadCertChain`/`loadPrivateKey`, not part of unified `TlsError`):

| Error | Description |
|-------|-------------|
| `TlsInvalidPem` | PEM decoding failed |
| `TlsNoCertificates` | No certificates found in PEM file |
| `TlsInvalidPrivateKey` | Private key PEM decoding failed |

See `errors.zig` for the full `TlsError` set.
