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

Configuration for TLS client connections.

```zig
pub const TlsConfig = struct {
    allocator: Allocator,
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    verify_server: bool = true,
    ca_bundle_path: ?[]const u8 = null,
};
```

### Factory Methods

| Method | Description |
|--------|-------------|
| `init(allocator)` | Default config (verify server, HTTP/1.1 only) |
| `insecure(allocator)` | Skip server verification |
| `withH2(allocator)` | Advertise h2 + http/1.1 ALPN |
| `insecureWithH2(allocator)` | Insecure + h2 ALPN |
| `withH3(allocator)` | Advertise h3 + h2 + http/1.1 ALPN |
| `insecureWithH3(allocator)` | Insecure + h3 ALPN |

## ServerTlsConfig

Configuration for TLS server connections. Holds loaded certificate chain and private key in DER format.

```zig
pub const ServerTlsConfig = struct {
    cert_chain_der: []const []const u8 = &.{},
    key_der: ?[]const u8 = null,
    allocator: ?Allocator = null,
    ecdsa_keypair: ?crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair = null,
};
```

### Loading from PEM Files

```zig
const server_tls = try tls.loadServerTlsConfig(allocator,
    "examples/certs/server_ec.crt",
    "examples/certs/server_ec.key",
);
defer server_tls.deinit();
```

## Server Configuration

Enable TLS on the server via `ServerConfig`:

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8443,
    .tls_enabled = true,
    .tls_cert_path = "examples/certs/server_ec.crt",
    .tls_key_path = "examples/certs/server_ec.key",
    .tls_alpn_protocols = &.{ "h3", "h2", "http/1.1" },
    .http2_enabled = true,
    .http3_enabled = true,
});
```

::: tip ALPN Default
The default `tls_alpn_protocols` is `&.{ "h3", "h2", "http/1.1" }`, so clients can negotiate HTTP/3, HTTP/2, or HTTP/1.1 automatically.
:::

The server automatically loads the certificate chain and private key on the first TLS connection. ALPN negotiation selects between HTTP/1.1, HTTP/2, and HTTP/3 based on the client's offer.

## Connection

The `Connection` struct represents an established TLS session over a TCP socket.

```zig
pub const Connection = struct {
    allocator: Allocator,
    socket: *Socket,
    negotiated_alpn: NegotiatedAlpn,
    tls_version: ProtocolVersion,
    is_server: bool,
    connected: bool,
    app_write_key: ?[32]u8,
    app_write_iv: ?[12]u8,
    app_read_key: ?[32]u8,
    app_read_iv: ?[12]u8,
    write_seq: u64,
    read_seq: u64,
    hs_write_seq: u64,
    hs_read_seq: u64,
    cipher_suite: ?CipherSuite,
};
```

### Methods

| Method | Description |
|--------|-------------|
| `negotiatedAlpn()` | Get the negotiated ALPN protocol string |
| `isHttp2()` | Returns true if HTTP/2 was negotiated |
| `isHttp3()` | Returns true if HTTP/3 was negotiated |
| `tlsVersion()` | Returns the negotiated TLS protocol version |
| `sendAlert(level, desc)` | Send a TLS alert to the peer |
| `closeNotify()` | Send close_notify alert for clean shutdown |
| `reader()` | Get an `AnyReader` for reading decrypted data |
| `writer()` | Get an `AnyWriter` for writing encrypted data |
| `read(buffer)` | Read decrypted data from the connection |
| `write(data)` | Write encrypted data to the connection |

## Client Handshake

Perform a full TLS 1.2 or 1.3 client handshake:

```zig
const connection = try tls.connectClient(allocator, socket, &config, "example.com");
defer connection.closeNotify();
```

## Server Handshake

Accept a TLS connection on the server side:

```zig
const connection = try tls.acceptServer(allocator, socket, alpn_protocols, server_tls_config);
defer connection.closeNotify();
```

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
// During handshake, certificate chain is verified automatically
const connection = try tls.connectClient(allocator, socket, &config, "example.com");
// If verification fails, returns error.TlsCertificateNotVerified or related errors
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
