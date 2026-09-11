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
| PSK resumption (`psk_dhe_ke` NST tickets) | -- | ✅ (native paths; std HTTPS/1.1 always full handshake) |
| HelloRetryRequest | -- | ✅ (both sides, single-retry guard) |
| 0-RTT early data | -- | ❌ intentionally unsupported (replay risk) |

## Architecture

```
tls.zig              -- Listener, TlsServer/TlsClient facades
├── engine.zig       -- TLS 1.3 handshake engine (both roles), key schedule
├── tcp_tls.zig      -- TLS 1.3 server transport (records, mTLS enforcement)
├── tcp_client.zig   -- TLS 1.3 client transport (ALPN offer, chain verify)
├── quic_tls.zig     -- RFC 9001 key schedule for TLS-in-QUIC
├── transport.zig    -- std-based HTTPS/1.1 client transport
├── handshake.zig    -- handshake message encode/decode, transcript
├── record.zig       -- record-layer AEAD encrypt/decrypt
├── certificate.zig  -- X.509 parsing (+ structural DER guard)
├── verify.zig       -- chain/hostname verification
├── trust_store.zig  -- system + custom trust anchors
├── config.zig       -- ServerConfig/ClientConfig (incl. mTLS fields)
├── alpn.zig         -- ALPN protocol negotiation
└── errors.zig       -- Unified TLS error set and alert conversion
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

## ServerTlsConfig

Server identity and ALPN preference (`src/protocols/tls/tcp_tls.zig`):

```zig
pub const TlsServerConfig = struct {
    allocator: Allocator,
    defaultIdentity: ?CertIdentity = null, // .{ .certChainPem, .privateKeyPem }
    certSelector: ?CertSelector = null,    // SNI selector, falls back to defaultIdentity
    alpnProtocols: []const alpn.Protocol = &alpn.DEFAULT_TCP_PREFERENCE,
    clientAuth: ClientAuthMode = .disabled, // .disabled / .optional / .required
    clientCaPem: ?[]const u8 = null,        // CA bundle trusted for client chains
};
```

## Server Configuration

Enable TLS on the server via `ServerConfig.tls` (PEM string or file path for
both entries):

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8443,
    .tls = .{
        .certPem = @embedFile("cert.pem"),
        .keyPem = @embedFile("key.pem"),
    },
    .http2 = true,
});
```

For a standalone TLS listener, use `httpx.tls.Listener`:

```zig
var listener = try httpx.tls.Listener.init(allocator, io, .{
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
The server negotiates ALPN from `alpnProtocols` (default TCP preference: h2 then http/1.1), so clients negotiate HTTP/2 or HTTP/1.1 automatically.
:::

The server automatically loads the certificate chain and private key on the first TLS connection. ALPN negotiation selects between HTTP/1.1, HTTP/2, and HTTP/3 based on the client's offer.

## Connection

Client connections flow through the high-level client (`client.get("https://…")`),
which performs the handshake, ALPN negotiation, hostname verification, and
record-layer encryption internally. Server connections are accepted by
`httpx.tls.Listener` / `Server.tls` and dispatched to HTTP/1 or HTTP/2
handlers based on the negotiated ALPN protocol.

### Methods (server side)

| Method | Description |
|--------|-------------|
| `httpx.tls.Listener.init(allocator, io, cfg)` | Bind a TLS listener with `defaultIdentity` |
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
