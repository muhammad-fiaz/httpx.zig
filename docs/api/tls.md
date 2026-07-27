# TLS API

The TLS module provides secure socket layer support for both client and server operations.

## TlsConfig

Configuration for TLS contexts.

```zig
pub const TlsConfig = struct {
    allocator: Allocator,
    min_version: TlsVersion = .tls_1_2,
    max_version: TlsVersion = .tls_1_3,
    verify_mode: VerifyMode = .peer,
    verify_hostname: bool = true,
    ca_file: ?[]const u8 = null,
    ca_path: ?[]const u8 = null,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    // ALPN protocols for protocol negotiation ("h2" for HTTP/2, "http/1.1").
    alpn_protocols: []const []const u8 = &.{ "http/1.1" },
    cipher_suites: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    allow_truncation_attacks: bool = true,
    force_h2: bool = false,
};
```

### Methods

#### `init`

Creates a default configuration (safe defaults).

```zig
pub fn init(allocator: Allocator) Self
```

#### `insecure`

Creates a configuration that skips verification (useful for testing).

```zig
pub fn insecure(allocator: Allocator) Self
```

#### `withH2`

Creates a configuration advertising HTTP/2 ALPN protocols (`"h2"`, `"http/1.1"`).

```zig
pub fn withH2(allocator: Allocator) Self
```

#### `insecureWithH2`

Creates an unverified configuration advertising HTTP/2 ALPN protocols.

```zig
pub fn insecureWithH2(allocator: Allocator) Self
```

## TlsSession

Manages a single TLS client connection over an attached TCP socket.

```zig
pub const TlsSession = struct {
    // State fields
    connected: bool,
    negotiated_protocol: ?[]const u8,
};
```

### Methods

- `attachSocket(socket: *Socket) void`: Attaches a connected socket for the session transport.
- `handshake(hostname: []const u8) !void`: Performs the TLS handshake using `std.crypto.tls.Client`.
- `read(buffer: []u8) !usize`: Decrypts and reads data.
- `write(data: []const u8) !usize`: Encrypts and writes data.
- `getReader() !*std.Io.Reader`: Returns a reader for decrypted TLS payload.
- `getWriter() !*std.Io.Writer`: Returns a writer for TLS-encrypted payload.
- `getAlpnProtocol() ?[]const u8`: Returns the negotiated ALPN protocol (e.g., `"h2"` for HTTP/2, `"h3"` for HTTP/3).
- `isHttp2() bool`: Returns `true` if HTTP/2 was negotiated via ALPN.

## Types

### `TlsVersion`

Enum: `.tls_1_0`, `.tls_1_1`, `.tls_1_2`, `.tls_1_3`.

### `VerifyMode`

Enum: `.none`, `.peer`, `.fail_if_no_peer_cert`, `.client_once`.
