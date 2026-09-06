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

1. Latest release (0.1.8)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz
```

2. Previous stable release (0.1.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.7.tar.gz
```

3. Legacy Zig 0.15 support (0.0.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.7.tar.gz
```

::: warning Zig 0.15 deprecation
Zig `0.15` is deprecated. It uses an older API surface and is only retained in `0.0.7`.
:::

4. Nightly/main branch

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig
```

5. Manual dependency entry in `build.zig.zon`

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz",
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
