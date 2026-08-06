# TLS API

The TLS module provides a fully custom TLS 1.2/1.3 implementation built entirely on `std.crypto` primitives. No dependency on `std.crypto.tls` -- all handshake, record-layer encryption, certificate verification, and ALPN negotiation is implemented from scratch.

## Supported Features

| Feature | TLS 1.2 | TLS 1.3 |
|---------|---------|---------|
| X25519 key exchange | ✅ | ✅ |
| P-256 key exchange | ✅ | ✅ |
| P-384 key exchange | ✅ | ✅ |
| AES-128-GCM | ✅ | ✅ |
| AES-256-GCM | ✅ | ✅ |
| ChaCha20-Poly1305 | ✅ | ✅ |
| Certificate loading (PEM) | ✅ | ✅ |
| Certificate chain serialization | ✅ | ✅ |
| ALPN negotiation | ✅ | ✅ |
| SNI extension | ✅ | ✅ |
| Custom CA trust store | ✅ | ✅ |
| Handshake message encryption | -- | ✅ |
| Cipher suite selection from client list | -- | ✅ |
| QUIC-TLS bridge | -- | ✅ |

## Architecture

```
tls.zig              -- High-level Connection, TlsConfig, TlsSession, ServerTlsConfig
├── handshake.zig    -- Shared handshake engine, KeyExchange (X25519/P-256/P-384)
├── handshake_12.zig -- TLS 1.2 client+server state machine
├── handshake_13.zig -- TLS 1.3 client+server state machine
├── record.zig       -- Record-layer AEAD encrypt/decrypt (TLS 1.2 explicit IV, TLS 1.3 implicit nonce)
├── extensions.zig   -- Extension encoding: SNI, ALPN, supported_versions, key_share, supported_groups, signature_algorithms, psk_key_exchange_modes
├── cipher_suites.zig-- Cipher suite registry and wire encoding
├── transcript.zig   -- Runtime-dispatched handshake transcript hash (SHA-256/384/512)
├── key_schedule.zig -- TLS 1.3 HKDF-based key schedule
├── cert_verify.zig  -- Certificate chain verification, ECDSA signing/verification, hostname verification
├── alpn.zig         -- ALPN protocol negotiation
├── errors.zig       -- Unified TLS error set and alert conversion
├── quic_bridge.zig  -- QUIC-TLS 1.3 bridge for HTTP/3
├── crypto_utils.zig -- Shared crypto utilities
└── trust_store.zig  -- CA trust store management
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
};
```

### Loading from PEM Files

```zig
const server_tls = try tls.loadServerTlsConfig(allocator,
    "examples/certs/server.crt",
    "examples/certs/server.key",
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
    .tls_cert_path = "examples/certs/server.crt",
    .tls_key_path = "examples/certs/server.key",
    .tls_alpn_protocols = &.{ "h2", "http/1.1" },
    .http2_enabled = true,
});
```

The server automatically loads the certificate chain and private key on the first TLS connection. ALPN negotiation selects between HTTP/1.1 and HTTP/2 based on the client's offer.

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

The cert_verify module handles X.509 certificate chain verification:

```zig
const cert_verify = @import("httpx").cert_verify;

// Parse a DER certificate
const cert = try cert_verify.parseCertificate(der_bytes);

// Verify hostname against certificate
try cert_verify.verifyHostname(&cert, "example.com");
```

## Trust Store

Manage trusted CA certificates:

```zig
const trust_store = @import("httpx").TrustStore;

var store = trust_store.TrustStore.init();
defer store.deinit(allocator);

// Load system trust store
try store.loadSystem(allocator);

// Load a PEM file
try store.loadPem(allocator, pem_data);

// Add a single DER certificate
try store.addCert(der_bytes);
```

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
| `x25519` | Default, fastest |
| `secp256r1` | NIST P-256 |
| `secp384r1` | NIST P-384 |

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
| `TlsInvalidPem` | PEM decoding failed |
| `TlsNoCertificates` | No certificates found in PEM file |
| `TlsInvalidPrivateKey` | Private key PEM decoding failed |

See `errors.zig` for the full error set.
