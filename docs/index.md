---
layout: home
title: httpx.zig
description: A production-grade, high-performance HTTP client and server library for Zig with HTTP/1.x, HTTP/2, HTTP/3, proxy support, concurrency, and protocol primitives.

hero:
  name: httpx.zig
  text: HTTP client and server library for Zig
  tagline: Production-grade HTTP/1.x/2/3 client and server runtime with proxy support, concurrency, and protocol primitives
  image:
    src: /httpx.zig-transparent.png
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
    details: Connection pooling, automatic retries, interceptors, typed API, and default-safe chainable config/option overrides.
  - title: Powerful Server
    details: Pattern-based routing, middleware support, context-based handling, ETag-aware static file helpers, and explicit port conflict startup strategies.
  - title: Concurrent
    details: Async task executor and parallel request patterns (all, any, race).
  - title: TLS Security
    details: Secure connections with TLS 1.2/1.3, custom CAs, and verification policies.
  - title: Low-level Control
    details: Direct access to sockets, buffers, protocol parsers, and HPACK/QPACK compression.
  - title: MIME Ready
    details: Case-insensitive MIME detection for common web/document/media/font/archive formats with explicit fallback override.
---

## Latest Benchmark Snapshot

Benchmark target: `x86_64-windows`, `ReleaseFast` (measured 2026-10-02).

| Benchmark | Category | Avg Latency | Throughput | Target |
| :--- | :--- | :---: | :---: | :---: |
| `headers_parse` | Core Operations | 257.49 ns/op | **3883591 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 35.65 ns/op | **28046635 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 2.23 ns/op | **449147518 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 19.74 ns/op | **50650119 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 24.58 ns/op | **40687786 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 263.30 ns/op | **3797967 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 1.02 µs/op | **977952 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 1.06 µs/op | **944143 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 1.03 µs/op | **970782 ops/sec** | `x86_64-windows` |
| `router_typed_match` | Routing | 1.14 µs/op | **880393 ops/sec** | `x86_64-windows` |
| `router_miss_404` | Routing | 1.81 µs/op | **550989 ops/sec** | `x86_64-windows` |
| `router_reverse` | Routing | 68.65 ns/op | **14565687 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 245.93 ns/op | **4066174 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 312.18 ns/op | **3203298 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 24.20 ns/op | **41328974 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 23.31 ns/op | **42897466 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 7.82 ns/op | **127813494 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 53.11 µs/op | **18830 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 6.64 µs/op | **150626 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 63.54 µs/op | **15737 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 6.48 µs/op | **154405 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 20.13 µs/op | **49668 ops/sec** | `x86_64-windows` |
| `template_parse` | Parsing | 2.90 µs/op | **345360 ops/sec** | `x86_64-windows` |
| `template_render` | Parsing | 1.46 µs/op | **683819 ops/sec** | `x86_64-windows` |
| `template_incremental` | Parsing | 22.94 µs/op | **43597 ops/sec** | `x86_64-windows` |
| `json_feed_parse` | Parsing | 3.78 µs/op | **264404 ops/sec** | `x86_64-windows` |
| `live_reload_inject` | Parsing | 230.33 ns/op | **4341596 ops/sec** | `x86_64-windows` |
| `watcher_scan` | Watcher | 1.14 ms/op | **879 ops/sec** | `x86_64-windows` |
| `watcher_deps` | Watcher | 4.21 µs/op | **237375 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 228.54 ns/op | **4375553 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 37.93 ns/op | **26365676 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 48.49 ns/op | **20623531 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.09 ns/op | **921523093 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 1.04 ns/op | **963131332 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 1.42 ns/op | **704508147 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 1.58 ns/op | **632739191 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.59 ns/op | **627817330 ops/sec** | `x86_64-windows` |
| `tls_record_seal` | TLS | 1.62 µs/op | **619051 ops/sec** | `x86_64-windows` |
| `tls_cert_parse` | TLS | 1.07 µs/op | **938620 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 387.84 µs/op | **2578 req/sec** | `x86_64-windows` |
| `h2_pooled_get` | Network | 55.89 µs/op | **17891 req/sec** | `x86_64-windows` |
| `h3_get` | Network | 205.89 ms/op | **4 req/sec** | `x86_64-windows` |
| `tls_full_handshake` | TLS | 4.35 ms/op | **230 ops/sec** | `x86_64-windows` |
| `tls_resumed_handshake` | TLS | 2.94 ms/op | **339 ops/sec** | `x86_64-windows` |


Detailed methodology and analysis: [Benchmarks Reference](/reference/benchmarks).

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Release (v0.2.1)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.1.tar.gz
```

**Previous Release (v0.1.8)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz
```

> [!WARNING]
> Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.16.0+** with **httpx.zig v0.2.1**.

### Method 2: Zig Fetch (Latest / v0.2.1 in development)

Use this for the latest in-development version from the `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.1.tar.gz",
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
- For **HTTP client/server** support, check out **[httpx.zig](https://github.com/muhammad-fiaz/httpx.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **file downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
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
| HTTP/1.0 | ✅ Full | TCP | Legacy support |
| HTTP/1.1 | ✅ Full | TCP/TLS | Default protocol |
| HTTP/2 | ✅ Client + Server Runtime + Primitives | TCP/TLS | High-level client/server execution paths plus full framing/HPACK/stream primitives |
| HTTP/3 | 🚧 Primitives | QUIC/UDP | Frame/QPACK/QUIC codec + unit tests; end-to-end transport forthcoming |

## Platform Support

httpx.zig is validated across Linux, Windows, and macOS:

| Platform | x86_64 | aarch64 | x86 |
|----------|--------|---------|-----|
| Linux    | ✅     | ✅      | ✅  |
| Windows  | ✅     | ✅      | ✅  |
| macOS    | ✅     | ✅      | ❌  |

## Examples

All examples are runnable from the repo root:

```bash
zig build run-all-simple_get
```

Runnable examples live in `examples/` (see the [README](https://github.com/muhammad-fiaz/httpx.zig#examples)
for the full list), including:

- `simpleServer.zig`: basic HTTP server
- `simpleGet.zig`: basic HTTP client GET
- `fullIntegration.zig`: end-to-end client + server lifecycle
- `websocketServer.zig`: WebSocket handshake and frames
- `sseServer.zig`: Server-Sent Events
- `multipart.zig`: multipart/form-data uploads
- `metricsServer.zig`: Prometheus exposition and snapshots
- `sessionServer.zig`: cookie-based session flow
- `healthCheck.zig`: liveness/readiness probes
- `proxyDemo.zig`: HTTP proxy and SOCKS5h tunneling
- `concurrentDemo.zig`: parallel getAll / requestAll
- `connectionPool.zig`: keep-alive pooling
- `staticFiles.zig`, `staticSite.zig`, `staticEmbedded.zig`: filesystem, site, and single-file embedded assets
- `spaServer.zig`, `spaFallback.zig`: single-page applications
- `http2Client.zig`, `http2Multiplex.zig`: HTTP/2 and HPACK
- `http3Client.zig`, `http3Quic.zig`: HTTP/3, QPACK, and QUIC framing
- `tlsServer.zig`, `tlsGet.zig`, `tlsMtls.zig`: TLS listener and identities
- `graphqlServer.zig`: GraphQL over HTTP
- `template-basic`, `template-loops`, `template-inheritance`, `template-includes`: template engine features
- `website`: embedded single-file website demo


## Configuration

Client configuration lives on `ClientConfig` (timeouts, redirects, retries, TLS verification, keep-alive/pooling).

For a full explicit export map (root aliases + API groups), see [API Overview](/api/).

## Validation

Use these commands to validate host runtime behavior and cross-target compatibility:

```bash
zig build test
zig build run-all-examples   # Runs sequentially to prevent parallel compiler OOM / PC crashes
zig build build-all-examples -Dtarget=x86_64-linux-gnu
```

To validate Linux runtime behavior, run the cross-compiled artifacts on Linux/WSL (a foreign-target `zig build test` only compiles; it does not execute):

```bash
zig build test -Dtarget=x86_64-linux-gnu
zig build run-simple-get -Dtarget=x86_64-linux-gnu

./zig-out/bin/test
./zig-out/bin/simple-get
```

For production client code, prefer explicit timeout + error handling so failures surface immediately:

```zig
var response = client.get(url, .{ .timeoutMs = 10_000 }) catch |err| {
  std.debug.print("request failed: {s}\n", .{@errorName(err)});
  return;
};
defer response.deinit();
```

For detailed target-matrix instructions, see [Installation](/guide/installation#validation-and-target-matrix).
