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
| `headers_parse` | Core Operations | 365.64 ns/op | **2734908 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 33.81 ns/op | **29580460 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 2.68 ns/op | **372929773 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 21.66 ns/op | **46168073 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 23.55 ns/op | **42454372 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 257.05 ns/op | **3890293 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 1.24 ┬╡s/op | **806411 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 1.25 ┬╡s/op | **801630 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 1.26 ┬╡s/op | **795854 ops/sec** | `x86_64-windows` |
| `router_typed_match` | Routing | 1.54 ┬╡s/op | **647704 ops/sec** | `x86_64-windows` |
| `router_miss_404` | Routing | 2.00 ┬╡s/op | **500509 ops/sec** | `x86_64-windows` |
| `router_reverse` | Routing | 83.98 ns/op | **11908206 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 276.36 ns/op | **3618459 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 343.94 ns/op | **2907485 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 25.63 ns/op | **39014646 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 23.96 ns/op | **41737794 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 10.96 ns/op | **91241791 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 76.54 ┬╡s/op | **13065 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 11.19 ┬╡s/op | **89353 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 50.75 ┬╡s/op | **19702 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 6.65 ┬╡s/op | **150313 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 19.21 ┬╡s/op | **52057 ops/sec** | `x86_64-windows` |
| `template_parse` | Parsing | 2.90 ┬╡s/op | **345276 ops/sec** | `x86_64-windows` |
| `template_render` | Parsing | 1.53 ┬╡s/op | **651719 ops/sec** | `x86_64-windows` |
| `template_incremental` | Parsing | 20.60 ┬╡s/op | **48548 ops/sec** | `x86_64-windows` |
| `json_feed_parse` | Parsing | 4.06 ┬╡s/op | **246242 ops/sec** | `x86_64-windows` |
| `live_reload_inject` | Parsing | 453.54 ns/op | **2204869 ops/sec** | `x86_64-windows` |
| `watcher_scan` | Watcher | 1.15 ms/op | **873 ops/sec** | `x86_64-windows` |
| `watcher_deps` | Watcher | 3.87 ┬╡s/op | **258305 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 218.84 ns/op | **4569510 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 42.82 ns/op | **23353082 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 54.96 ns/op | **18196507 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.14 ns/op | **873835614 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 0.91 ns/op | **1095338240 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 1.50 ns/op | **668127639 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 1.82 ns/op | **550518312 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.78 ns/op | **562667041 ops/sec** | `x86_64-windows` |
| `tls_record_seal` | TLS | 1.52 ┬╡s/op | **658921 ops/sec** | `x86_64-windows` |
| `tls_cert_parse` | TLS | 1.05 ┬╡s/op | **955103 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 385.93 ┬╡s/op | **2591 req/sec** | `x86_64-windows` |
| `h2_pooled_get` | Network | 53.50 ┬╡s/op | **18691 req/sec** | `x86_64-windows` |
| `h3_get` | Network | 206.05 ms/op | **4 req/sec** | `x86_64-windows` |
| `tls_full_handshake` | TLS | 4.34 ms/op | **230 ops/sec** | `x86_64-windows` |
| `tls_resumed_handshake` | TLS | 2.82 ms/op | **354 ops/sec** | `x86_64-windows` |


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
