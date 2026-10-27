# Getting Started

`httpx.zig` is a modern, feature-rich HTTP library for the Zig programming language. It is under active development, supporting robust client and server implementations with focus on performance and developer experience.

## Features

- **Protocol Support**: HTTP/1.0/1.1/2/3 client/server runtime paths plus full HTTP/2 and HTTP/3 protocol primitives.
- **Cross-Platform**: Validated on Linux, Windows, and macOS with x86_64, aarch64, and x86 architectures.
- **Client**:
    - Connection pooling and keep-alive.
    - Automatic retries with configurable linear backoff.
    - Cookie helpers and a standalone RFC 6265 cookie jar.
    - Structured lifecycle events through a client callback.
    - Idiomatic, grouped configuration structs with sensible defaults.
- **Server**:
    - Pattern-based routing.
    - Middleware architecture.
    - Static file serving.
    - JSON helpers.
- **Concurrency**: Built-in thread pool and async primitives (`all`, `any`, `race`).
- **Security**: Native TLS 1.3 with ALPN negotiation, TLS 1.2 interoperability through the standard-library HTTPS/1.1 transport, ECDSA certificate verification, and custom CA handling.
- **Modern Architecture**: Minimal, unified client and server APIs, explicit resource ownership, and zero boilerplate.

::: warning Custom HTTP/2, HTTP/3, and TLS Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, or an ALPN hook. **httpx.zig implements these protocols entirely from scratch**, including:
- **TLS 1.3** native server and client handshakes (RFC 8446) with X25519, AEAD record protection (ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM), ALPN negotiation (RFC 7301), X.509 parsing and verification, mutual TLS, session resumption, HelloRetryRequest, and opt-in 0-RTT. TLS 1.2 remains available through the standard-library HTTPS/1.1 client transport.
- **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
- **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 9113)
- **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
- **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, ACK/loss recovery, NewReno congestion control, flow control, transport parameters, 0-RTT resumption, and RFC 9001 handshake confirmation/key discard
- **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
:::

## Requirements

- **Zig Version**: 0.17.0 or later
- **Operating System**: Windows, Linux, or macOS

::: warning Upgrading from 0.2.x and older
v0.2.3 is a breaking release (Zig `0.17.0` required) with no
compatibility wrappers. Review the updated Client/Server/Router usage
in this guide when migrating from `0.2.2` (or older).
:::

## Platform Support

### Operating Systems

| Platform | Status | Notes |
|----------|--------|-------|
| Linux    | ✅ Full | All major distributions (Ubuntu, Debian, Fedora, Arch, etc.) |
| Windows  | ✅ Full | Windows 10/11, Server 2019+ |
| macOS    | ✅ Full | macOS 11+ (Big Sur and later) |

### Architectures

| Architecture | Linux | Windows | macOS | Notes |
|--------------|-------|---------|-------|-------|
| x86_64 (64-bit) | ✅ | ✅ | ✅ | Primary development target |
| aarch64 (ARM64) | ✅ | ✅ | ✅ | Apple Silicon, AWS Graviton, Raspberry Pi 4+ |
| x86 (32-bit) | ✅ | ✅ | ❌ | Legacy x86 support on Linux/Windows |

### Cross-Compilation

Zig's built-in cross-compilation makes it easy to build for any target:

```bash
# Build for Linux x86_64
zig build -Dtarget=x86_64-linux

# Build for Linux ARM64
zig build -Dtarget=aarch64-linux

# Build for Windows x86_64
zig build -Dtarget=x86_64-windows

# Build for Windows x86 (32-bit)
zig build -Dtarget=x86-windows

# Build for macOS ARM64 (Apple Silicon)
zig build -Dtarget=aarch64-macos

# Build for macOS x86_64 (Intel)
zig build -Dtarget=x86_64-macos
```

## Next Steps

- Check out the [Installation](/guide/installation) guide to add `httpx.zig` to your project.
- Learn how to make [Basic Requests](/guide/client-basics) with the client.
- Set up a simple [Server](/guide/routing).
- Explore [HTTP/2](/guide/http2) and [HTTP/3](/guide/http3) protocol support.
- Review [API Overview](/api/) for explicit root exports and aliases.
