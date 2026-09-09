# TLS API

The TLS module provides a fully custom TLS 1.2/1.3 implementation built entirely on `std.crypto` primitives. No dependency on `std.crypto.tls` — all handshake, record-layer encryption, certificate verification, and ALPN negotiation is implemented from scratch.

::: warning Custom Implementation
Zig's standard library does not provide TLS/ALPN support. **httpx.zig implements TLS entirely from scratch**, including:
- **TLS 1.2 and 1.3** with full handshake support (RFC 5246 / RFC 8446)
- **Key exchange:** X25519 (TLS 1.2/1.3)
- **AEAD cipher suites:** ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM
- **ALPN negotiation** (RFC 7301) for automatic HTTP/2 and HTTP/3 protocol selection with HTTP/1.1 fallback
- **Handshake message encryption** (TLS 1.3)
- **X.509 certificate parsing and verification** (client-side)
- **Custom record-layer encryption/decryption**
:::

## Supported Features

| Feature | TLS 1.2 | TLS 1.3 |
|---------|---------|---------|
| X25519 key exchange | ✅ | ✅ |
| AES-128-GCM | ✅ | ✅ |
| AES-256-GCM | ✅ | ✅ |
| ChaCha20-Poly1305 | ✅ | ✅ |
| ECDSA P-256 certificate signing | -- | ✅ |
| Certificate loading (PEM) | ✅ | ✅ |
| Certificate chain verification (client-side) | ✅ | ✅ |
| ALPN negotiation | ✅ | ✅ |
| SNI extension | ✅ | ✅ |
| Handshake message encryption | -- | ✅ |
| Cipher suite selection from client list | -- | ✅ |

## Architecture

```
tls.zig              -- High-level Connection, TlsConfig, TlsSession, record-layer AEAD encrypt/decrypt
├── client.zig       -- TLS 1.2/1.3 client handshake, X25519 key exchange, cipher suite negotiation
├── server.zig       -- TLS 1.2/1.3 server handshake, ServerHello, cipher selection
├── alpn.zig         -- ALPN protocol negotiation
└── errors.zig       -- Unified TLS error set and alert conversion
```

## TlsConfig (Client)

Per-request and client-level TLS options (`src/client/request.zig`):

```zig
pub const TlsOptions = struct {
    verify: VerifyMode = .caBundle, // .caBundle, .selfSigned, .none
    caBundle: ?*std.crypto.Certificate.Bundle = null,
    allowTruncation: bool = true,
};
```

```zig
// Development-only verification bypass:
var res = try client.get("https://127.0.0.1:8443/", .{ .tls = .{ .verify = .none } });
```

## ServerTlsConfig

Server identity and ALPN preference (`src/protocols/tls/tcp_tls.zig`):

```zig
pub const TlsServerConfig = struct {
    allocator: Allocator,
    defaultIdentity: ?CertIdentity = null, // .{ .certChainPem, .privateKeyPem }
    certSelector: ?CertSelector = null,    // SNI selector, falls back to defaultIdentity
    alpnProtocols: []const alpn.Protocol = &alpn.DEFAULT_TCP_PREFERENCE,
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
