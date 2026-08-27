<div align="center">
<img src="https://github.com/user-attachments/assets/ae3e1cc2-41f8-4326-b757-c9afcf6c8fea" alt="httpx.zig logo" width="400" />

<a href="https://muhammad-fiaz.github.io/httpx.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/badge/version-0.2.0-blue" alt="Version"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/httpx.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/httpx.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">

<p><em>A production-ready, high-performance HTTP client and server library for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/httpx.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/api/client">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

**httpx.zig** is a native Zig HTTP/networking library providing HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3, TLS 1.3, QUIC, ALPN negotiation, and a web framework.

> [!TIP]
> If you build with httpx.zig, make sure to give it a star. ⭐

> [!NOTE]
> **v0.2.0** is a major release. Every protocol layer was built from scratch as a modular, testable, production-grade native Zig implementation.
>
> **Why a custom implementation?** Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, or TLS/ALPN support. httpx.zig implements these protocols natively:
> - **TLS 1.3** -- X25519 key exchange, HKDF key schedule (RFC 8446 Section 7.1), AEAD encryption (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305), transcript hashing, ALPN negotiation (RFC 7301), SNI, PEM certificate loading, record-layer encryption/decryption
> - **HTTP/2** -- HPACK header compression (RFC 7541), stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, CONTINUATION frames, PING, bidirectional concurrent streams
> - **HTTP/3** -- QPACK header compression (RFC 9204), control stream, request streams, SETTINGS, GOAWAY, frame handling
> - **QUIC** -- Initial/Handshake/1-RTT packets, packet protection and header protection (RFC 9001), ACK tracking, loss detection, NewReno congestion control (RFC 9002), connection IDs, path validation, transport parameters, stream management
> - **HTTP/1.0 and HTTP/1.1** -- Parser with request-smuggling defenses, chunked encoding, trailers, keep-alive, pipelining, Content-Length, Transfer-Encoding, HEAD/CONNECT/OPTIONS
> - **WebSocket** -- RFC 6455 upgrade handshake, masking, fragmentation, ping/pong
> - **SSE** -- Server-Sent Events writer and parser
> - **ALPN** -- Correctly integrated across TCP+TLS (`h2`, `http/1.1`, `http/1.0`) and QUIC (`h3`) with server/client preference ordering
> - **Client** -- Zero-config and explicit client APIs, connection pooling, cookie jar, DNS cache, redirect following
> - **Server** -- HTTP/1.1 server with routing, keep-alive, TLS/ALPN dispatch to HTTP/1.x or HTTP/2
> - **Router** -- Pattern matching (static, parameter, wildcard routes), method-based dispatch
> - **Compression** -- gzip, deflate, brotli, zstd with content negotiation (Accept-Encoding / Content-Encoding)
> - **DNS** -- Resolution with caching, concurrent resolver coalescing
> - **SOCKS5** -- Proxy tunneling with remote DNS
> - **FTP** -- PASV/EPSV, TLS enforcement, directory listing
> - **Web framework** -- Middleware, security headers (CORS, CSRF), static file serving with ETag/Range, SPA fallback, OpenAPI spec generation, health endpoints, Prometheus metrics, multipart encoder/parser, Basic and Bearer auth

**Related Zig projects:**

- For **env.zig** (.env parsing), check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **ZON file format** support, check out **[zon.zig](https://github.com/muhammad-fiaz/zon.zig)**.
- For **spinners/loading/progress bar** support, check out **[loaders.zig](https://github.com/muhammad-fiaz/loaders.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.
- For **args parsing** support, check out **[args.zig](https://github.com/muhammad-fiaz/args.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **CUDA** support, check out **[cuda.zig](https://github.com/muhammad-fiaz/cuda.zig)**.
- For **Simplified build.zig config** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.
- For **SQLite (zig-native implementation)** support, check out **[sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig)**.
- For **file downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
- For **UUID** support, check out **[uuid.zig](https://github.com/muhammad-fiaz/uuid.zig)**.
- For **key-value database** support, check out **[zkv.zig](https://github.com/muhammad-fiaz/zkv.zig)**.
- For **terminal color & text styles** support, check out **[hint.zig](https://github.com/muhammad-fiaz/hint.zig)**.
- For **Brotli compression (Native Implementation)** support, check out **[brotli.zig](https://github.com/muhammad-fiaz/brotli.zig)**.
- For **Zstandard compression (Native Implementation)** support, check out **[zstd.zig](https://github.com/muhammad-fiaz/zstd.zig)**.

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| **Zig** | **0.16.0** (stable) |
| **Operating System** | Windows, Linux, macOS |

### Supported Platforms

| Platform | x86_64 | aarch64 | x86 (32-bit) |
|----------|--------|---------|--------------|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes | No |

### Cross-Compilation

```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows

# Build for macOS Apple Silicon from Linux
zig build -Dtarget=aarch64-macos
```

---

## Installation

### Method 1: Zig Fetch (Recommended)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 2: Manual `build.zig.zon`

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.0.tar.gz",
        .hash = "...", // Run zig fetch --save <url> to generate
    },
},
```

### Method 3: Local Source

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

```zig
.dependencies = .{
    .httpx = .{ .path = "../httpx.zig" },
},
```

### Wire into `build.zig`

```zig
const httpx_dep = b.dependency("httpx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
```

---

## Quick Start

### Zero-Config Client

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    // Simplest possible GET request
    var resp = try httpx.get(.{ .url = "https://httpbin.org/get" });
    defer resp.deinit();

    std.debug.print("Status: {d}\n", .{@intFromEnum(resp.status)});

    // POST JSON
    var post = try httpx.post(.{
        .url = "https://httpbin.org/post",
        .json = "{\"name\":\"Alice\"}",
    });
    defer post.deinit();
}
```

---

## Protocol Support

| Protocol | Status | Notes |
|----------|--------|-------|
| **HTTP/1.0** | Complete | Parser with smuggling defenses, chunked encoding, trailers |
| **HTTP/1.1** | Complete | Keep-alive, pipelining, Content-Length, Transfer-Encoding |
| **HTTP/2** | Complete | HPACK, SETTINGS, GOAWAY, PING, flow control, CONTINUATION |
| **HTTP/3** | Complete | QPACK, control stream, SETTINGS, frame handling |
| **TLS 1.3** | Complete | X25519, HKDF, AEAD, ALPN, SNI, certificate loading |
| **QUIC** | Complete | Initial/Handshake/1-RTT, congestion control, loss detection |
| **WebSocket** | Complete | RFC 6455 upgrade, masking, fragmentation, ping/pong |
| **SSE** | Complete | Server-Sent Events writer and parser |
| **FTP** | Complete | PASV/EPSV, TLS enforcement, directory listing |
| **DNS** | Complete | Resolution with caching, concurrent resolver coalescing |
| **SOCKS5** | Complete | Proxy tunneling with remote DNS |
| **Compression** | Complete | gzip, deflate, brotli, zstd with content negotiation |

### ALPN Negotiation

ALPN is fully integrated across all transport layers:

- **TCP + TLS**: `h2`, `http/1.1`, `http/1.0`
- **QUIC**: `h3`

Server preference and client preference are handled correctly. `h3` is never selected over TCP/TLS.

---

## Architecture

```
src/
  common/       - Shared primitives (errors, headers, URI, methods, logging, sync)
  sockets/      - TCP + UDP wrappers (std.Io based)
  net/          - Addresses (IPv4+IPv6), DNS, SOCKS5, proxy
  protocols/
    http1/      - Parser, writer, semantics, fuzz testing
    http2/      - Frame codec, HPACK, streams, connection, transport
    http3/      - Frame types, QPACK, connection
    quic/       - Packet codec, crypto, protection, ACK tracking,
                  loss detection, congestion control, streams,
                  connection IDs, path validation, transport params
    tls/        - ALPN, engine, handshake, record, config,
                  TCP-TLS transport, TLS server, QUIC-TLS
    common/     - Huffman coding, prefix integers
    ftp/        - FTP client
  compression/  - Codec negotiation, zstd, brotli
  web/
    router/     - Pattern matching, metadata, router
    middleware/  - Security headers (CORS, CSRF, rate limiting)
    sse/        - Writer and parser
    websocket/  - Handshake and frame codec
    auth/       - Basic and Bearer token
    multipart/  - Encoder and parser
    docs/       - Swagger UI, ReDoc, Scalar assets
    openapi/    - Spec generation from router
    static_files/ - Serving with ETag, Range, MIME
    spa/        - Single-page app fallback
    health/     - Liveness and readiness endpoints
    metrics/    - Prometheus-compatible registry
  server/       - Lifecycle (accept loop, router dispatch, keep-alive)
  client/       - Request engine, connection pool, cookie jar
  integration/  - HTTP/1.1 and TLS integration tests
```

---

## Validation

```bash
# Run all tests (338 pass, 1 platform-specific skip)
zig build test

# Format check
zig fmt src/

# Cross-target compile check
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
```

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.
