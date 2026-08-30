---
layout: home
title: httpx.zig
description: A production-ready, high-performance HTTP client and server library for Zig with HTTP/1.x, HTTP/2, HTTP/3, proxy support, concurrency, and protocol primitives.

hero:
  name: httpx.zig
  text: HTTP client and server library for Zig
  tagline: Production-ready HTTP/1.x/2/3 client and server runtime with proxy support, concurrency, and protocol primitives
  image:
    src: /logo.png
    alt: httpx.zig
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /api/client
    - theme: alt
      text: View on GitHub
      link: https://github.com/muhammad-fiaz/httpx.zig

features:
  - title: All HTTP Versions
    details: Full HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 client/server runtime support, plus full protocol primitives.
  - title: Robust Client
    details: Connection pooling, automatic retries with configurable backoff, close/reset lifecycle, typed JSON requests, and zero-config defaults.
  - title: Powerful Server
    details: Pattern-based routing (httpx.router.pattern), middleware support, context-based handling (queryParam, cookie, remoteAddress), lifecycle management (run, start, stop, pause, resumeAccepting), and ETag-aware static file helpers.
  - title: Concurrent
    details: Async task executor and parallel request patterns (all, any, race).
  - title: TLS Security
    details: Secure connections with TLS 1.2/1.3, custom CAs, ALPN negotiation, and TlsListener lifecycle (run, stop, requestShutdown).
  - title: Low-level Control
    details: Direct access to sockets, buffers, protocol parsers, and HPACK/QPACK compression.
  - title: MIME Ready
    details: Case-insensitive MIME detection for common web/document/media/font/archive formats with explicit fallback override.
---

## Latest Benchmark Snapshot

Benchmark target: `x86_64-windows`, `ReleaseFast`.

| Benchmark | Avg (ns/op) | Throughput (ops/sec) |
|-----------|-------------|----------------------|
| headers_parse | 14669.17 | 68170 |
| uri_parse | 32.03 | 31220048 |
| status_lookup | 0.95 | 1054585337 |
| method_lookup | 14.72 | 67941706 |
| base64_encode | 4707.96 | 212406 |
| base64_decode | 4766.07 | 209816 |
| json_builder | 5066.82 | 197362 |
| request_build | 25681.18 | 38939 |
| response_builders | 25546.64 | 39144 |
| executor_run_all | 198.41 | 5039997 |
| proxy_request_build | 41799.37 | 23923 |
| h2_frame_header | 1.00 | 1001883541 |
| h3_varint_encode | 0.91 | 1100589475 |

## Install

::: warning v0.1.8 release and Zig 0.15 deprecation
`v0.1.8` is the current release and targets Zig `0.16.0+`.
`v0.1.7` is the previous stable release for the immediate prior `0.1.x` line.
Zig `0.15` support is legacy and remains available only through `0.0.7`.
The HTTPS/TLS reader fix for Zig `0.16` empty-buffer reads is included in this release.
If you are upgrading from `0.0.7`, review the GitHub Releases page for migration notes.
:::

Choose one of these installation methods:

1. Latest stable release (0.1.8)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.0.tar.gz
```

2. Previous stable release (0.1.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz
```

3. Legacy Zig 0.15 support (0.0.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.7.tar.gz
```

::: warning Zig 0.15 deprecation
Zig `0.15` is deprecated. It uses an older API surface and is only retained in `0.0.7`.
:::

4. Dev branch (latest)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

5. Manual dependency entry in `build.zig.zon`

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.0.tar.gz",
    .hash = "...",
  },
},
```

::: tip Release maturity
httpx.zig is built with production-readiness as a core goal. It is still a relatively new project, so adoption is growing. You can use it in real projects while tracking changelogs between releases.
:::

::: tip Related Zig Projects
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
:::

For full setup details, including local path dependencies and `build.zig` wiring, see `/guide/installation`.

::: warning Custom HTTP/2, HTTP/3, and TLS Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, or TLS/ALPN support. **httpx.zig implements these protocols entirely from scratch**, including:
- **TLS 1.2 and 1.3** with full handshake support (RFC 5246 / RFC 8446) — key exchange: X25519 (TLS 1.2/1.3); AEAD cipher suites: ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM; ALPN negotiation (RFC 7301) for automatic HTTP/2 and HTTP/3 protocol selection with HTTP/1.1 fallback; handshake message encryption (TLS 1.3); X.509 certificate parsing and verification (client-side); custom record-layer encryption/decryption
- **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
- **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 7540)
- **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
- **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, version negotiation, and transport parameters
- **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
- **Interop note:** strict TLS-in-QUIC server negotiation expectations may vary by endpoint deployment
:::

## Protocol Support

| Protocol | Status | Transport | Notes |
|----------|--------|-----------|-------|
| HTTP/1.0 | Full | TCP | Legacy support |
| HTTP/1.1 | Full | TCP/TLS | Default protocol |
| HTTP/2 | Client + Server Runtime + Primitives | TCP/TLS | High-level client/server execution paths plus full framing/HPACK/stream primitives |
| HTTP/3 | Client + Server Runtime + Primitives | QUIC/UDP | High-level client/server runtime over UDP + QUIC/HTTP3/QPACK primitives |

## Platform Support

httpx.zig is validated across Linux, Windows, and macOS:

| Platform | x86_64 | aarch64 | x86 |
|----------|--------|---------|-----|
| Linux    | Yes    | Yes     | Yes |
| Windows  | Yes    | Yes     | Yes |
| macOS    | Yes    | Yes     | No  |

For detailed installation instructions, see [Installation](/guide/installation).
