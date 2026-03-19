# Getting Started

`httpx.zig` is a modern, feature-rich HTTP library for the Zig programming language. It is designed to be production-ready, supporting robust client and server implementations with focus on performance and developer experience.

## Features

- **Protocol Support**: Production-ready HTTP/1.1 client/server runtime plus HTTP/2 (HPACK/streams) and HTTP/3 (QPACK/QUIC) protocol primitives.
- **Cross-Platform**: Works on Linux, Windows, macOS, and FreeBSD with x86_64, aarch64, and i386 architectures.
- **Client**:
    - Connection pooling and keep-alive.
    - Automatic retries with exponential backoff.
    - Request/Response interceptors.
    - Cookie management.
- **Server**:
    - Pattern-based routing.
    - Middleware architecture.
    - Static file serving.
    - JSON helpers.
- **Concurrency**: Built-in thread pool and async primitives (`all`, `any`, `race`).
- **Security**: TLS/SSL support (via `std.crypto` or system libraries) with custom CA handling.

::: warning Custom HTTP/2 & HTTP/3 Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols entirely from scratch**, including HPACK (RFC 7541), QPACK (RFC 9204), HTTP/2 framing (RFC 7540), and QUIC transport (RFC 9000).
:::

## Requirements

- **Zig Version**: 0.15.0 or later (tested on 0.15.2)
- **Operating System**: Windows, Linux, macOS, or FreeBSD

## Platform Support

### Operating Systems

| Platform | Status | Notes |
|----------|--------|-------|
| Linux    | ✅ Full | All major distributions (Ubuntu, Debian, Fedora, Arch, etc.) |
| Windows  | ✅ Full | Windows 10/11, Server 2019+ |
| macOS    | ✅ Full | macOS 11+ (Big Sur and later) |
| FreeBSD  | ✅ Full | FreeBSD 13+ |

### Architectures

| Architecture | Linux | Windows | macOS | Notes |
|--------------|-------|---------|-------|-------|
| x86_64 (64-bit) | ✅ | ✅ | ✅ | Primary development target |
| aarch64 (ARM64) | ✅ | ✅ | ✅ | Apple Silicon, AWS Graviton, Raspberry Pi 4+ |
| i386 (32-bit) | ✅ | ✅ | ✅ | Legacy x86 support |
| arm (32-bit) | ✅ | ✅ | ✅ | Raspberry Pi 3 and earlier, ARM Cortex |

### Cross-Compilation

Zig's built-in cross-compilation makes it easy to build for any target:

```bash
# Build for Linux x86_64
zig build -Dtarget=x86_64-linux

# Build for Linux ARM64
zig build -Dtarget=aarch64-linux

# Build for Windows x86_64
zig build -Dtarget=x86_64-windows

# Build for Windows i386 (32-bit)
zig build -Dtarget=i386-windows

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
