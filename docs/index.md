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
    details: HTTP/1.0, HTTP/1.1, and HTTP/2 runtimes; HTTP/3 client/server runtime for reliable paths, with QUIC loss recovery and congestion control still unimplemented.
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

Benchmark target: `x86_64-windows`, `ReleaseFast` (measured 2026-10-09, httpx v0.2.2, Zig 0.17.0).

| Benchmark | Category | Avg Latency | Throughput | Target |
| :--- | :--- | :---: | :---: | :---: |
| `headers_parse` | Core Operations | 271.30 ns/op | **3686008 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 30.42 ns/op | **32871921 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 3.16 ns/op | **316829675 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 22.05 ns/op | **45347669 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 46.39 ns/op | **21554557 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 292.25 ns/op | **3421724 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 300.20 ns/op | **3331168 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 374.60 ns/op | **2669548 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 304.44 ns/op | **3284695 ops/sec** | `x86_64-windows` |
| `router_typed_match` | Routing | 389.81 ns/op | **2565368 ops/sec** | `x86_64-windows` |
| `router_miss_404` | Routing | 518.20 ns/op | **1929753 ops/sec** | `x86_64-windows` |
| `router_reverse` | Routing | 123.88 ns/op | **8072640 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 243.83 ns/op | **4101157 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 365.35 ns/op | **2737138 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 36.74 ns/op | **27220513 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 14.66 ns/op | **68220269 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 1.07 ns/op | **935663759 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 24.71 µs/op | **40466 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 8.99 µs/op | **111290 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 19.69 µs/op | **50780 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 7.60 µs/op | **131503 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 22.68 µs/op | **44096 ops/sec** | `x86_64-windows` |
| `template_parse` | Parsing | 2.80 µs/op | **356959 ops/sec** | `x86_64-windows` |
| `template_render` | Parsing | 1.75 µs/op | **569931 ops/sec** | `x86_64-windows` |
| `template_incremental` | Parsing | 24.64 µs/op | **40581 ops/sec** | `x86_64-windows` |
| `json_feed_parse` | Parsing | 4.12 µs/op | **242809 ops/sec** | `x86_64-windows` |
| `live_reload_inject` | Parsing | 230.46 ns/op | **4339210 ops/sec** | `x86_64-windows` |
| `watcher_scan` | Watcher | 1.16 ms/op | **865 ops/sec** | `x86_64-windows` |
| `watcher_deps` | Watcher | 3.90 µs/op | **256433 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 238.37 ns/op | **4195121 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 50.50 ns/op | **19801039 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 56.17 ns/op | **17802432 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.05 ns/op | **954162054 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 1.43 ns/op | **700020300 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 4.12 ns/op | **242468915 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 1.54 ns/op | **647320417 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.57 ns/op | **637649369 ops/sec** | `x86_64-windows` |
| `tls_record_seal` | TLS | 1.29 µs/op | **777763 ops/sec** | `x86_64-windows` |
| `tls_cert_parse` | TLS | 1.04 µs/op | **961840 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 54.61 µs/op | **18310 req/sec** | `x86_64-windows` |
| `h2_pooled_get` | Network | 48.72 µs/op | **20524 req/sec** | `x86_64-windows` |
| `h3_get` | Network | 206.02 ms/op | **4 req/sec** | `x86_64-windows` |
| `tls_full_handshake` | TLS | 3.40 ms/op | **294 ops/sec** | `x86_64-windows` |
| `tls_resumed_handshake` | TLS | 2.85 ms/op | **350 ops/sec** | `x86_64-windows` |


Detailed methodology and analysis: [Benchmarks Reference](/reference/benchmarks).

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Release (v0.2.2)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.2.tar.gz
```

**Previous Release (v0.2.1)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.1.tar.gz
```

> [!WARNING]
> Zig **0.16** is deprecated and supported only by **v0.2.1**, and Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.17.0+** with **httpx.zig v0.2.2**.

### Method 2: Zig Fetch (Latest Development Build)

Use this for the latest in-development version from the `main` branch. It may contain unreleased changes:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.2.tar.gz",
    .hash = "<actual-hash-generated-by-zig-fetch>", // Run `zig fetch --save <url>` to generate the hash.
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
- For **terminal colors & text styles** support, check out **[tint.zig](https://github.com/muhammad-fiaz/tint.zig)**.
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
| HTTP/2 | ✅ Full | TCP/TLS | Client + server runtime (ALPN `h2` / h2c) plus framing/HPACK/stream primitives |
| HTTP/3 | ⚠️ Reliable paths | QUIC/TLS | Client + server runtime (ALPN `h3`); no loss recovery, congestion control, Retry, or version negotiation |

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
