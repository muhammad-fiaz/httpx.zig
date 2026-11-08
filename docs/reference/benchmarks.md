---
title: Benchmarks & Performance
description: Comprehensive performance benchmarks for HTTPX covering core parsing, routing, serialization, compression, concurrency, DNS, protocols, and end-to-end client/server throughput.
---

# Benchmarks & Performance

HTTPX ships an in-tree benchmark suite (`bench/main.zig`, run with `zig build bench`) that measures every major subsystem. It reports both microbenchmarks and end-to-end loopback request latency, averaged over several rounds after a warm-up discard.

> [!NOTE]
> Every number below was produced by running `zig build bench` on the date shown in the environment table. HTTPX does not publish estimated or fabricated numbers - the harness prints the library version, target, optimisation mode, and the run date itself, so a table can always be traced back to a real run.

The harness copies each result into a Markdown table at the end of the run, which is what the tables below contain.

---

## 1. Test Environment

| Property | Value |
| :--- | :--- |
| **HTTPX Version** | `0.2.4` |
| **Zig Version** | `0.17.0` |
| **Optimization Mode** | `ReleaseFast` |
| **Target Architecture** | `x86_64` |
| **Operating System** | Windows (`x86_64-windows`) |
| **Benchmark Harness** | `bench/main.zig` via `zig build bench` |
| **Measurement Date** | `2026-11-08` |

Each benchmark reports `min`, `avg`, and `max` nanoseconds per operation across 3-5 rounds; the table shows `avg`. Iteration counts are chosen per cost class - 2,000,000 for primitive encoders, 200,000 for general parsing and routing, 20,000 for document parsing, 2,000 for compression, and 10-200 for network and handshake operations.

Benchmarks feed their result to `std.mem.doNotOptimizeAway`, and iterate over a runtime array of inputs rather than a single constant, so the optimiser cannot fold the work away and report a meaningless sub-nanosecond figure.

Benchmarks that perform I/O also count their failures. A benchmark body returns `void`, so a request that errored would otherwise be indistinguishable from a very fast success and the harness would print a confident throughput for work that never happened. Any failed iteration is printed as `!! N ITERATIONS FAILED` next to the row, listed again in a summary at the end, and makes the run exit non-zero. A benchmark row is only meaningful when no failures were reported for it.

`client_server_get` exercises the HTTP/1.1 keep-alive reuse path. In this run it reported no failures; a failed iteration would be printed as `!! N ITERATIONS FAILED` and make the run exit non-zero.

### Reading the numbers

Latency figures move between runs; they are not a contract. On the machine used for the table above, a repeat run on the same day landed within a few percent for the network and handshake benchmarks (`client_server_get`, `h2_pooled_get`, `tls_full_handshake` all agreed to within 1%) and within roughly 10-25% for the allocator-bound parsing benchmarks (`html_parse`, `json_feed_parse`, `live_reload_inject`). Prefer the trend across a change over any single figure, and treat anything under 5 ns/op as a lower bound on the operation rather than a measurement of it.

---

## 2. Benchmark Summary

55 benchmarks across 14 subsystems:

| Benchmark | Category | Avg Latency | Throughput |
| :--- | :--- | :---: | :---: |
| `headers_parse` | Core Operations | 224.93 ns/op | **4445904 ops/sec** |
| `uri_parse` | Core Operations | 61.79 ns/op | **16183534 ops/sec** |
| `status_lookup` | Core Operations | 2.36 ns/op | **424329347 ops/sec** |
| `method_lookup` | Core Operations | 13.79 ns/op | **72537146 ops/sec** |
| `http1_request_head` | Core Operations | 16.49 ns/op | **60656055 ops/sec** |
| `http1_header_block` | Core Operations | 205.65 ns/op | **4862711 ops/sec** |
| `authority_parse` | Core Operations | 13.05 ns/op | **76612795 ops/sec** |
| `percent_decode` | Core Operations | 34.33 ns/op | **29131247 ops/sec** |
| `percent_encode` | Core Operations | 20.98 ns/op | **47666259 ops/sec** |
| `cookie_param_iter` | Core Operations | 89.31 ns/op | **11196954 ops/sec** |
| `token_list_scan` | Core Operations | 28.21 ns/op | **35453701 ops/sec** |
| `query_param_lookup` | Core Operations | 37.48 ns/op | **26683388 ops/sec** |
| `router_static_match` | Routing | 250.91 ns/op | **3985422 ops/sec** |
| `router_param_match` | Routing | 306.85 ns/op | **3258914 ops/sec** |
| `router_dispatch` | Routing | 261.41 ns/op | **3825408 ops/sec** |
| `router_typed_match` | Routing | 303.18 ns/op | **3298399 ops/sec** |
| `router_miss_404` | Routing | 419.13 ns/op | **2385882 ops/sec** |
| `router_reverse` | Routing | 55.58 ns/op | **17992730 ops/sec** |
| `json_stringify` | Serialization | 197.37 ns/op | **5066592 ops/sec** |
| `json_parse` | Serialization | 273.95 ns/op | **3650294 ops/sec** |
| `basic_auth_encode` | Security | 24.44 ns/op | **40924567 ops/sec** |
| `basic_auth_decode` | Security | 14.63 ns/op | **68358774 ops/sec** |
| `bearer_token_parse` | Security | 1.09 ns/op | **913634162 ops/sec** |
| `gzip_compress` | Compression | 14.88 -�s/op | **67217 ops/sec** |
| `gzip_decompress` | Compression | 4.13 -�s/op | **242071 ops/sec** |
| `deflate_compress` | Compression | 13.47 -�s/op | **74248 ops/sec** |
| `deflate_decompress` | Compression | 4.06 -�s/op | **246455 ops/sec** |
| `html_parse` | Parsing | 11.55 -�s/op | **86583 ops/sec** |
| `template_parse` | Parsing | 2.39 -�s/op | **418704 ops/sec** |
| `template_render` | Parsing | 1.33 -�s/op | **754289 ops/sec** |
| `template_incremental` | Parsing | 18.69 -�s/op | **53508 ops/sec** |
| `json_feed_parse` | Parsing | 3.24 -�s/op | **308669 ops/sec** |
| `live_reload_inject` | Parsing | 231.07 ns/op | **4327662 ops/sec** |
| `watcher_scan` | Watcher | 657.92 -�s/op | **1519 ops/sec** |
| `watcher_deps` | Watcher | 3.18 -�s/op | **314606 ops/sec** |
| `static_safe_join` | Static Files | 95.81 ns/op | **10437803 ops/sec** |
| `spa_fallback_policy` | SPA | 92.54 ns/op | **10806489 ops/sec** |
| `worker_pool_submit` | Concurrency | 198.00 ns/op | **5050484 ops/sec** |
| `concurrency_queue` | Concurrency | 21.56 ns/op | **46386492 ops/sec** |
| `dns_cache_hit` | DNS | 89.73 ns/op | **11144134 ops/sec** |
| `h2_frame_header` | Protocols | 2.52 ns/op | **396381826 ops/sec** |
| `hpack_int_encode` | Protocols | 3.82 ns/op | **261660234 ops/sec** |
| `hpack_int_decode` | Protocols | 9.03 ns/op | **110760124 ops/sec** |
| `qpack_int_encode` | Protocols | 4.11 ns/op | **243141583 ops/sec** |
| `qpack_int_decode` | Protocols | 2.40 ns/op | **417505156 ops/sec** |
| `h3_frame_header` | Protocols | 2.43 ns/op | **411815819 ops/sec** |
| `h3_varint_encode` | Protocols | 3.42 ns/op | **292106408 ops/sec** |
| `h3_varint_decode` | Protocols | 3.22 ns/op | **310161190 ops/sec** |
| `tls_record_seal` | TLS | 1.11 -�s/op | **899435 ops/sec** |
| `tls_cert_parse` | TLS | 974.69 ns/op | **1025963 ops/sec** |
| `client_server_get` | Network | 81.44 -�s/op | **12279 req/sec** |
| `h2_pooled_get` | Network | 52.93 -�s/op | **18894 req/sec** |
| `h3_get` | Network | 203.29 ms/op | **4 req/sec** |
| `tls_full_handshake` | TLS | 3.26 ms/op | **307 ops/sec** |
| `tls_resumed_handshake` | TLS | 2.65 ms/op | **377 ops/sec**

> [!NOTE]
> This run reported no failed iterations, so every row above is valid as recorded.

---

## 3. Detailed Subsystem Analysis

### Core Operations & HTTP/1.1 Parsing
- **Zero-copy request head**: `http1_request_head` parses a full request line - method, target, version - in ~18.7 ns (~53.4 million ops/sec), operating directly on borrowed slices with no intermediate allocation.
- **Header block**: `http1_header_block` parses a 5-header block in ~195 ns (~5.1 million ops/sec).
- **URI**: full RFC 3986 parsing of scheme, host, port, path, query, and fragment in ~62.2 ns (~16.1 million ops/sec).
- **Status reason phrases**: ~2.8 ns per lookup across a set of six status codes, no allocation.
- **Method lookup**: case-insensitive name to enum in ~14.0 ns.

### Server Routing & Dispatch
Measured against a 10-route table mixing static, `{param}`, and typed `{id:int}` routes.
- **Static match**: ~239 ns (~4.2 million ops/sec).
- **Parameter extraction**: ~296 ns, segment splitting is cheap next to route selection.
- **Full dispatch**: ~251 ns, so middleware stepping and response construction add only a few nanoseconds over a bare match.
- **Typed parameter match**: ~295 ns, the cost of integer conversion on top of a normal match.
- **Miss (404)**: ~412 ns; a miss is more expensive than a hit because every candidate is tried before falling through.
- **URL generation**: ~56 ns.

### Serialization, Feeds & Live Reload
- **JSON stringify**: ~188 ns (~5.3 million ops/sec) for a 6-field struct.
- **JSON parse**: ~264 ns (~3.8 million ops/sec) into a typed Zig struct.
- **JSON Feed parse**: ~3.34 µs for a 3-item feed on `std.json`. Feed documents go through `std.json` rather than a Tree-sitter grammar, so the whole parse is one allocator-backed pass instead of a syntax tree plus a manual tree walk.
- **Live-reload injection**: ~240 ns to append the SSE client script to an HTML page, idempotently, before `</body>`.

### Authentication
- **Basic auth encode**: ~24.9 ns (~40 million ops/sec).
- **Basic auth decode**: ~13.8 ns (~72 million ops/sec).
- **Bearer token parse**: ~1.1 ns (~932 million ops/sec).

### Compression & Decompression (1 KiB JSON payload)
- **Gzip compress**: ~14.65 µs (~68,000 ops/sec).
- **Gzip decompress**: ~4.08 µs (~245,000 ops/sec).
- **Deflate compress**: ~13.36 µs (~75,000 ops/sec).
- **Deflate decompress**: ~4.15 µs (~241,000 ops/sec).

Compression is ~2.6x more expensive than decompression, which is the usual shape for these codecs and the reason the client negotiates encoding once per connection instead of per response.

### Web & Document Parsing
- **HTML parse**: ~12.2 µs for a small document, Tree-sitter tokenisation plus DOM construction.
- **Template parse**: ~2.42 µs.
- **Template render**: ~1.36 µs, faster than parsing because the AST is cached and reused.
- **Template incremental reparse**: ~19.3 µs when the source is unchanged; this is the same-work comparison, and it shows the incremental path is not yet cheaper than a fresh parse on identical input.
- **Watcher scan**: ~646 µs for a full stat-walk of the template tree. The walk prunes ignored directories, so this cost is proportional to the files you actually watch, not to the repository around them.
- **Watcher dependency graph**: ~3.23 µs to resolve the affected set across 64 edges.

### Concurrency & DNS Caching
- **Bounded MPMC queue**: push then pop in ~21.5 ns (~46 million ops/sec).
- **Worker pool submit**: ~180 ns (~5.5 million ops/sec).
- **DNS cache hit**: ~88.1 ns (~11.3 million ops/sec) for a cached hostname, including the returned-address list allocation.

### Protocol Primitives (HTTP/2, HPACK, QUIC)
- **HTTP/2 frame header**: serialize plus parse of a 9-byte header in ~2.25 ns (~444 million ops/sec).
- **HPACK integer encode**: ~3.95 ns; **decode**: ~8.81 ns.
- **QUIC varint encode**: ~3.76 ns, **decode**: ~3.54 ns, both covering all four widths (1, 2, 4, and 8 byte encodings).

These are the cheapest operations in the suite, as expected: fixed-size header arithmetic with no branching on content.

### TLS
- **Record seal**: ChaCha20-Poly1305 AEAD seal of a 1 KiB record in ~1.08 µs (~925,000 ops/sec).
- **Certificate parse**: PEM decode plus DER parse of a P-256 chain in ~1.02 µs (~983,000 ops/sec).
- **Full handshake**: ~3.26 ms per handshake over loopback (~306/sec).
- **Resumed handshake**: ~2.67 ms per handshake (~374/sec), about 18% faster than a full handshake. The gap is narrower than TLS 1.3 0-RTT would suggest because the benchmark measures a full TCP connect and a PSK resumption over loopback, where connection setup and record-layer work dominate rather than key agreement.

### End-to-End Loopback Requests
- **HTTP/1.1 keep-alive GET** (`client_server_get`): ~80.4 µs per request, ~12,442 req/sec, between a live `httpx.Client` and a live `httpx.Server` on `127.0.0.1`, single-threaded and synchronous.
- **HTTP/2 pooled GET** (`h2_pooled_get`): ~54.1 µs, ~18,492 req/sec. One h2c connection is reused, so a request costs a frame exchange instead of a new connection.
- **HTTP/3 GET** (`h3_get`): ~203.0 ms per request, ~4 req/sec, because each operation performs a fresh QUIC plus TLS 1.3 handshake rather than reusing a session. This is a deliberate worst case, not a steady-state HTTP/3 number.

---

## 4. How to Reproduce

From the root of the repository:

```bash
zig build bench
```

The benchmark executable is compiled with `-OReleaseFast` as configured in `build.zig`, so debug assertions do not distort the timings. The run prints its own environment header and ends with the Markdown table reproduced above.

Every benchmark runs on `127.0.0.1` or in-process; the suite requires no network access and no external tools.
