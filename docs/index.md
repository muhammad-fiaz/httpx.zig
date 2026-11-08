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
    details: HTTP/1.0, HTTP/1.1, and HTTP/2 runtimes; HTTP/3 client/server runtime over QUIC with loss recovery, NewReno congestion control, flow control, and 0-RTT resumption.
  - title: Robust Client
    details: Connection pooling, automatic retries, a typed API, and default-safe chainable config/option overrides.
  - title: Powerful Server
    details: Pattern-based routing, middleware support, context-based handling, ETag-aware static file helpers, and explicit port conflict startup strategies.
  - title: Concurrent
    details: Async task executor and parallel request patterns (all, any, race).
  - title: TLS Security
    details: Native TLS 1.3 server and client paths, TLS 1.2 client interoperability, custom CAs, and verification policies.
  - title: Advanced Protocol Access
    details: Optional standalone HTTP/1, HTTP/2, HTTP/3, QUIC, and TLS types for protocol work; ordinary client and server code never needs to construct frames or packets.
  - title: MIME Ready
    details: Case-insensitive MIME detection for common web/document/media/font/archive formats with explicit fallback override.
---

## Latest Benchmark Snapshot

Benchmark target: `x86_64-windows`, `ReleaseFast` (measured 2026-11-08, httpx v0.2.4, Zig 0.17.0).

| Benchmark | Category | Avg Latency | Throughput |
| :--- | :--- | :---: | :---: |
| `headers_parse` | Core Operations | 221.49 ns/op | **4514882 ops/sec** |
| `uri_parse` | Core Operations | 68.36 ns/op | **14629208 ops/sec** |
| `status_lookup` | Core Operations | 2.35 ns/op | **426368322 ops/sec** |
| `method_lookup` | Core Operations | 14.10 ns/op | **70926462 ops/sec** |
| `http1_request_head` | Core Operations | 20.30 ns/op | **49253077 ops/sec** |
| `http1_header_block` | Core Operations | 193.31 ns/op | **5173027 ops/sec** |
| `authority_parse` | Core Operations | 11.01 ns/op | **90813324 ops/sec** |
| `percent_decode` | Core Operations | 30.32 ns/op | **32984902 ops/sec** |
| `percent_encode` | Core Operations | 22.21 ns/op | **45022331 ops/sec** |
| `cookie_param_iter` | Core Operations | 78.80 ns/op | **12689936 ops/sec** |
| `token_list_scan` | Core Operations | 28.72 ns/op | **34819911 ops/sec** |
| `query_param_lookup` | Core Operations | 39.31 ns/op | **25440178 ops/sec** |
| `router_static_match` | Routing | 286.30 ns/op | **3492798 ops/sec** |
| `router_param_match` | Routing | 331.05 ns/op | **3020703 ops/sec** |
| `router_dispatch` | Routing | 283.97 ns/op | **3521482 ops/sec** |
| `router_typed_match` | Routing | 328.54 ns/op | **3043773 ops/sec** |
| `router_miss_404` | Routing | 460.00 ns/op | **2173910 ops/sec** |
| `router_reverse` | Routing | 59.07 ns/op | **16928035 ops/sec** |
| `json_stringify` | Serialization | 190.77 ns/op | **5241977 ops/sec** |
| `json_parse` | Serialization | 279.62 ns/op | **3576328 ops/sec** |
| `basic_auth_encode` | Security | 24.54 ns/op | **40753615 ops/sec** |
| `basic_auth_decode` | Security | 13.80 ns/op | **72442770 ops/sec** |
| `bearer_token_parse` | Security | 1.06 ns/op | **947292637 ops/sec** |
| `gzip_compress` | Compression | 15.46 ┬╡s/op | **64674 ops/sec** |
| `gzip_decompress` | Compression | 4.26 ┬╡s/op | **234965 ops/sec** |
| `deflate_compress` | Compression | 14.10 ┬╡s/op | **70932 ops/sec** |
| `deflate_decompress` | Compression | 4.30 ┬╡s/op | **232776 ops/sec** |
| `html_parse` | Parsing | 12.00 ┬╡s/op | **83305 ops/sec** |
| `html_parse_large` | Parsing | 20.50 ms/op | **48 pages/sec** |
| `template_parse` | Parsing | 2.49 ┬╡s/op | **401097 ops/sec** |
| `template_render` | Parsing | 1.40 ┬╡s/op | **716827 ops/sec** |
| `template_incremental` | Parsing | 44.49 ┬╡s/op | **22475 ops/sec** |
| `json_feed_parse` | Parsing | 3.35 ┬╡s/op | **298141 ops/sec** |
| `live_reload_inject` | Parsing | 224.73 ns/op | **4449817 ops/sec** |
| `watcher_scan` | Watcher | 650.99 ┬╡s/op | **1536 ops/sec** |
| `watcher_deps` | Watcher | 3.41 ┬╡s/op | **292948 ops/sec** |
| `static_safe_join` | Static Files | 92.25 ns/op | **10839673 ops/sec** |
| `spa_fallback_policy` | SPA | 94.22 ns/op | **10613590 ops/sec** |
| `worker_pool_submit` | Concurrency | 211.88 ns/op | **4719654 ops/sec** |
| `concurrency_queue` | Concurrency | 23.03 ns/op | **43413329 ops/sec** |
| `dns_cache_hit` | DNS | 87.81 ns/op | **11387939 ops/sec** |
| `h2_frame_header` | Protocols | 2.32 ns/op | **431721142 ops/sec** |
| `hpack_int_encode` | Protocols | 3.37 ns/op | **296837199 ops/sec** |
| `hpack_int_decode` | Protocols | 8.76 ns/op | **114207791 ops/sec** |
| `qpack_int_encode` | Protocols | 3.39 ns/op | **295036599 ops/sec** |
| `qpack_int_decode` | Protocols | 2.15 ns/op | **464634355 ops/sec** |
| `h3_frame_header` | Protocols | 2.40 ns/op | **416396009 ops/sec** |
| `h3_varint_encode` | Protocols | 3.15 ns/op | **317430086 ops/sec** |
| `h3_varint_decode` | Protocols | 2.96 ns/op | **338002271 ops/sec** |
| `tls_record_seal` | TLS | 1.09 ┬╡s/op | **919299 ops/sec** |
| `tls_cert_parse` | TLS | 993.24 ns/op | **1006806 ops/sec** |
| `client_server_get` | Network | 80.86 ┬╡s/op | **12366 req/sec** |
| `h2_pooled_get` | Network | 51.48 ┬╡s/op | **19423 req/sec** |
| `h3_get` | Network | 203.15 ms/op | **4 req/sec** |
| `tls_full_handshake` | TLS | 3.42 ms/op | **292 ops/sec** |
| `tls_resumed_handshake` | TLS | 2.78 ms/op | **359 ops/sec** |


Detailed methodology and analysis: [Benchmarks Reference](/reference/benchmarks).

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Release (v0.2.4)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.4.tar.gz
```

> [!NOTE]
> **httpx.zig** requires Zig **0.17.0+**.
>
> For documentation matching older releases of `httpx.zig`, checkout that release's tag and generate local documentation using `zig build docs`, which emits native HTML documentation into `zig-out/docs/`.

### Method 2: Zig Fetch (Latest Development Build)

Use this for the latest in-development version from the `main` branch. It may contain unreleased changes:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.4.tar.gz",
    .hash = "<actual-hash-generated-by-zig-fetch>", // Run `zig fetch --save <url>` to generate the hash.
  },
},
```

::: tip Release status
This documentation describes `httpx.zig` `v0.2.4` for Zig `0.17.0`.
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
Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, or an ALPN hook. **httpx.zig implements these protocols entirely from scratch**, including:
- **TLS 1.3** native server and client handshakes (RFC 8446) with X25519 (including hybrid X25519MLKEM768), AEAD record protection (ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM), ALPN negotiation (RFC 7301), X.509 parsing and verification, mutual TLS, session resumption, HelloRetryRequest, and opt-in 0-RTT. TLS 1.2 is available through the `std.crypto.tls` HTTPS/1.1 client transport.
- **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
- **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 9113)
- **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
- **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, ACK/loss recovery, NewReno congestion control, flow control, transport parameters, 0-RTT resumption, and RFC 9001 handshake confirmation/key discard
- **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
:::

## Capabilities

| Area | Coverage |
|------|----------|
| HTTP client and server | HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 with connection pooling, retries, redirects, timeouts, and streaming |
| Web framework | Routing, middleware, typed REST, GraphQL, multipart, cookies, sessions, authentication, static files, templates, SPA hosting, OpenAPI, and documentation UIs |
| Protocols | Native HTTP/1.x, HTTP/2 (HPACK), HTTP/3 (QPACK), QUIC, TLS 1.3, TLS 1.2 client transport, FTP, and FTPS |
| Data and operations | JSON with declarative schemas, HTML/XML/feed parsing, compression, downloads, metrics, health checks, CORS, CSRF, and rate limiting |

::: tip Advanced protocol APIs
High-level `httpx.Client` and `httpx.Server` manage framing, HPACK/QPACK, QUIC
packets, TLS records, pooling, and cleanup internally. Use the standalone
`httpx.http1`, `httpx.http2`, `httpx.http3`, `httpx.quic`, and `httpx.tls`
types when you need protocol-level control.
:::

## Protocol Support

| Protocol | Transport | Capabilities |
|----------|-----------|--------------|
| HTTP/1.0 | TCP | Legacy message handling |
| HTTP/1.1 | TCP/TLS | Default protocol with keep-alive, chunked transfer, and `100-continue` |
| HTTP/2 | TCP/TLS | Client and server runtime (ALPN `h2` / h2c), multiplexing, HPACK, flow control, and connection pooling |
| HTTP/3 | QUIC/TLS | Client and server runtime (ALPN `h3`), QPACK, loss recovery, congestion control, flow control, Retry validation, version negotiation, key updates, 0-RTT, and connection pooling |

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
zig build run-simple-get
```

Runnable examples live in `examples/` (see the [README](https://github.com/muhammad-fiaz/httpx.zig#examples)
for the full list), including:

- `simpleServer.zig`: basic HTTP server
- `simpleGet.zig`: basic HTTP client GET
- `fullIntegration.zig`: end-to-end client + server lifecycle
- `websocketServer.zig`: WebSocket handshake response
- `sseServer.zig`: Server-Sent Events
- `multipart.zig`: multipart/form-data uploads
- `metricsServer.zig`: Prometheus exposition and snapshots
- `sessionServer.zig`: cookie-based session flow
- `healthCheck.zig`: liveness/readiness probes
- `proxyDemo.zig`: HTTP proxy and SOCKS5h tunneling
- `concurrentDemo.zig`: concurrent requests with worker pool
- `connectionPool.zig`: keep-alive pooling
- `staticFiles.zig`, `staticSite.zig`, `staticEmbedded.zig`: filesystem, site, and single-file embedded assets
- `server.zig`, `spaFallback.zig`: single-page applications
- `http2Client.zig`, `http2Multiplex.zig`: HTTP/2 and HPACK
- `http3Client.zig`, `http3Quic.zig`: HTTP/3, QPACK, and QUIC framing
- `tlsServer.zig`, `tlsGet.zig`, `tlsMtls.zig`: TLS listener and identities
- `graphqlServer.zig`: GraphQL over HTTP
- `template-basic`, `template-loops`, `template-inheritance`, `template-includes`: template engine features
- `website`: embedded single-file website demo


## Configuration

Client configuration is passed to `Client.init` (timeouts, redirects, retries, TLS verification, keep-alive/pooling).

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
fn fetchHealth(allocator: std.mem.Allocator, io: std.Io) !void {
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var response = client.get("https://api.example.com/health", .{
        .timeoutMs = 10_000,
    }) catch |err| {
        std.debug.print("request failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer response.deinit();

    if (!response.isSuccess()) {
        std.debug.print("unexpected status: {d}\n", .{response.status});
        return error.HttpStatusError;
    }
}
```

For detailed target-matrix instructions, see [Installation](/guide/installation#validation-and-target-matrix).
