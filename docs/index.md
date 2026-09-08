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

Benchmark target: `x86_64-windows`, `ReleaseFast` (measured 2026-09-07).

| Benchmark | Category | Avg Latency | Throughput | Target |
| :--- | :--- | :---: | :---: | :---: |
| `headers_parse` | Core Operations | 273.73 ns/op | **3,653,226 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 34.36 ns/op | **29,105,048 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 1.06 ns/op | **940,698,374 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 10.25 ns/op | **97,558,596 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 23.81 ns/op | **42,002,864 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 224.34 ns/op | **4,457,450 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 1.01 µs/op | **988,272 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 1.10 µs/op | **912,934 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 1.10 µs/op | **911,344 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 293.18 ns/op | **3,410,848 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 441.95 ns/op | **2,262,686 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 54.86 ns/op | **18,227,253 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 26.43 ns/op | **37,834,933 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 8.17 ns/op | **122,465,274 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 68.65 µs/op | **14,566 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 8.80 µs/op | **113,688 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 67.62 µs/op | **14,789 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 8.11 µs/op | **123,295 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 1.51 µs/op | **661,640 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 206.42 ns/op | **4,844,557 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 68.82 ns/op | **14,529,667 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 68.99 ns/op | **14,494,140 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.19 ns/op | **840,703,500 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 1.02 ns/op | **976,247,888 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 1.53 ns/op | **653,906,765 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 0.91 ns/op | **1,097,526,175 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.15 ns/op | **869,920,750 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 376.20 µs/op | **2,658 req/sec** | `x86_64-windows` |

Detailed methodology and analysis: [Benchmarks Reference](/reference/benchmarks).

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Stable Release (v0.2.0)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.0.tar.gz
```

**Previous Stable Release (v0.1.8)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz
```

> [!WARNING]
> Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.16.0+** with **httpx.zig v0.2.0**.

### Method 2: Zig Fetch (Latest / v0.2.0 in development)

Use this for the latest in-development version from the `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

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
| HTTP/3 | ✅ Client + Server Runtime + Primitives | QUIC/UDP | High-level client/server runtime over UDP + QUIC/HTTP3/QPACK primitives |

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

Available examples (see the `/examples` folder):

- `simple_get.zig`: minimal GET
- `simple_get_deserialize.zig`: GET request with typed JSON deserialization
- `json_api_example.zig`: JSON API: getJson, postJsonAndParse, Response.json, server ctx.jsonBody + ctx.json
- `post_json.zig`: JSON POST
- `custom_headers.zig`: request headers
- `interceptors.zig`: request/response interception hooks
- `middleware_example.zig`: middleware chain
- `router_example.zig`: router + handlers
- `simple_server.zig`: basic HTTP server
- `streaming.zig`: streaming request/response bodies
- `concurrent_requests.zig`: concurrency patterns
- `connection_pool.zig`: keep-alive pooling
- `cookies_demo.zig`: cookie jar management
- `simplified_api_aliases.zig`: simplified top-level/client aliases
- `static_files.zig`: file-based static routes and directory-based wildcard mounts for CSS/JS/images
- `multi_page_website.zig`: full multi-page website serving index/about/contact with static assets
- `http2_example.zig`: HTTP/2 HPACK compression and stream management
- `http2_client_runtime.zig`: local end-to-end high-level HTTP/2 client runtime demo
- `http2_server_runtime.zig`: local end-to-end high-level HTTP/2 server runtime demo
- `http3_example.zig`: HTTP/3 QPACK compression and QUIC framing
- `http3_client_runtime.zig`: local end-to-end high-level HTTP/3 client runtime demo
- `http3_server_runtime.zig`: local end-to-end high-level HTTP/3 server runtime demo
- `http2_advanced.zig`: HTTP/2 production features (SETTINGS enforcement, GOAWAY/RST_STREAM, HPACK security, trailers)
- `http3_advanced.zig`: HTTP/3 production features (QPACK stream instructions, QUIC stream cancellation, transport parameters)
- `tls_https_get.zig`: Simple HTTPS GET via local TLS server (HTTP/1.1 + HTTP/2 + HTTP/3)
- `tls_config_options.zig`: TLS configuration constructors and ALPN negotiation
- `tls_handshake_details.zig`: TLS handshake info and cipher suites
- `tls_custom_ca.zig`: Custom CA certificate verification with self-signed certs
- `tls_mtls.zig`: Mutual TLS client certificate authentication
- `tcp_local.zig`: local TCP listener/client round trip
- `udp_local.zig`: UDP local networking utility (prints human-readable `ip:port` for source address)
- `unix_socket_example.zig`: Unix domain socket IPC client/server (Linux, macOS; Windows 10 build 17061+ only)
- `websocket_example.zig`: WebSocket frame encoding/decoding and handshake helpers
- `multipart_example.zig`: multipart/form-data builder and parser
- `metrics_example.zig`: observability counters and latency tracking
- `session_example.zig`: TTL-based session store with server integration
- `health_check_example.zig`: liveness and readiness probe middleware
- `proxy_example.zig`: HTTP proxy and SOCKS5h tunneling
- `async_server_example.zig`: server thread pool concurrency and request handling on background workers
- `logging_callback.zig`: custom logging, silent mode, and log_level filtering
- `request_response_customization.zig`: request and response builder patterns
- `http_auth_helpers.zig`: Bearer and Basic auth helpers

> **Platform note — Unix domain sockets:** `unix_socket_example.zig` requires Linux, macOS, or Windows 10 build 17061+ with Developer Mode. On unsupported Windows builds the example prints a clear message and exits gracefully.


## Configuration

Client configuration lives on `ClientConfig` (timeouts, redirects, retries, TLS verification, keep-alive/pooling).

For a full explicit export map (root aliases + API groups), see [API Overview](/api/).

## Validation

Use these commands to validate host runtime behavior and cross-target compatibility:

```bash
zig build test
zig build run-all-examples   # Runs sequentially to prevent parallel compiler OOM / PC crashes
zig build build-all-targets
```

To validate Linux runtime behavior (not just compile checks), build Linux artifacts and run them from Linux/WSL:

```bash
zig build test -Dtarget=x86_64-linux
zig build run-all-tcp_local -Dtarget=x86_64-linux

./zig-out/bin/test
./zig-out/bin/tcp_local
```

For production client code, prefer explicit timeout + error handling so failures surface immediately:

```zig
var response = client.get(url, .{ .timeout_ms = 10_000 }) catch |err| {
  std.debug.print("request failed: {s}\n", .{@errorName(err)});
  return;
};
defer response.deinit();
```

For detailed target-matrix instructions, see [Installation](/guide/installation#validation-and-target-matrix).
