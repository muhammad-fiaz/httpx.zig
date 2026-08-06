# Getting Started

`httpx.zig` is a modern, feature-rich HTTP library for the Zig programming language. It is designed to be production-ready, supporting robust client and server implementations with focus on performance and developer experience.

## Features

- **Protocol Support**: Production-ready HTTP/1.0/1.1/2/3 client/server runtime paths plus full HTTP/2 and HTTP/3 protocol primitives.
- **Cross-Platform**: Validated on Linux, Windows, and macOS with x86_64, aarch64, and x86 architectures.
- **Client**:
    - Connection pooling and keep-alive.
    - Automatic retries with exponential backoff.
    - Request/Response interceptors.
    - Cookie management.
    - Optional chainable config/option builders (`ClientConfig.defaults().with...`, `RequestOptions.defaults().with...`) when you want explicit overrides.
- **Server**:
    - Pattern-based routing.
    - Middleware architecture.
    - Static file serving.
    - JSON helpers.
- **Concurrency**: Built-in thread pool and async primitives (`all`, `any`, `race`).
- **Security**: Custom TLS 1.2/1.3 implementation with ALPN negotiation, ECDSA certificate verification, and custom CA handling.
- **Explicit Root Helpers**: Top-level aliases for requests (`fetch/send/...`), concurrency (`first/fastest/settled`), networking (`resolveAddress`, `parseAndResolveAddress`, `netInit/netDeinit`), and MIME detection (`mimeTypeFromPath`, `mimeTypeFromPathOr`, `mimeTypeFromPathWith`) with external mapping support via `MimeMapping`.

::: warning Custom HTTP/2 & HTTP/3 Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols entirely from scratch**, including HPACK (RFC 7541), QPACK (RFC 9204), HTTP/2 framing (RFC 7540), and QUIC transport (RFC 9000).
:::

## Requirements

- **Zig Version**: 0.16.0 or later
- **Operating System**: Windows, Linux, or macOS

::: warning v0.1.4 release and Zig 0.15 deprecation
`v0.1.4` is the current release and targets Zig `0.16.0+`.
`v0.1.2` is the previous stable release for the immediate prior `0.1.x` line.
Zig `0.15` support is legacy and remains available only through `0.0.7`.
The HTTPS/TLS reader fix for Zig `0.16` empty-buffer reads is included in this release.
If you are upgrading from `0.0.7`, review the GitHub Releases page for migration notes.
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
