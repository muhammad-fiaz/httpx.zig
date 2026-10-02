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
| **HTTPX Version** | `0.2.1` |
| **Zig Version** | `0.16.0` |
| **Optimization Mode** | `ReleaseFast` |
| **Target Architecture** | `x86_64` |
| **Operating System** | Windows (`x86_64-windows`) |
| **Benchmark Harness** | `bench/main.zig` via `zig build bench` |
| **Measurement Date** | `2026-10-02` |

Each benchmark reports `min`, `avg`, and `max` nanoseconds per operation across 3-5 rounds; the table shows `avg`. Iteration counts are chosen per cost class - 2,000,000 for primitive encoders, 200,000 for general parsing and routing, 20,000 for document parsing, 2,000 for compression, and 10-200 for network and handshake operations.

Benchmarks feed their result to `std.mem.doNotOptimizeAway`, and iterate over a runtime array of inputs rather than a single constant, so the optimiser cannot fold the work away and report a meaningless sub-nanosecond figure.

Benchmarks that perform I/O also count their failures. A benchmark body returns `void`, so a request that errored would otherwise be indistinguishable from a very fast success and the harness would print a confident throughput for work that never happened. Any failed iteration is printed as `!! N ITERATIONS FAILED` next to the row, listed again in a summary at the end, and makes the run exit non-zero. A benchmark row is only meaningful when no failures were reported for it.

`client_server_get` is the one row that still reports a small number of failures on some runs: the HTTP/1.1 keep-alive connection is occasionally closed by the server between the client's reuse and its next write. That is a real reuse race in the loopback path rather than a measurement artefact, and it is why the row is marked rather than quietly averaged away.

### Reading the numbers

Latency figures move between runs; they are not a contract. On the machine used for the table above, a repeat run on the same day landed within a few percent for the network and handshake benchmarks (`client_server_get`, `h2_pooled_get`, `tls_full_handshake` all agreed to within 1%) and within roughly 10-25% for the allocator-bound parsing benchmarks (`html_parse`, `json_feed_parse`, `live_reload_inject`). Prefer the trend across a change over any single figure, and treat anything under 5 ns/op as a lower bound on the operation rather than a measurement of it.

---

## 2. Benchmark Summary

44 benchmarks across 12 subsystems:

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

---

## 3. Detailed Subsystem Analysis

### Core Operations & HTTP/1.1 Parsing
- **Zero-copy request head**: `http1_request_head` parses a full request line - method, target, version - in ~23.6 ns (~42.5 million ops/sec), operating directly on borrowed slices with no intermediate allocation.
- **Header block**: `http1_header_block` parses a 5-header block in ~257 ns (~3.9 million ops/sec).
- **URI**: full RFC 3986 parsing of scheme, host, port, path, query, and fragment in ~33.8 ns (~29.6 million ops/sec).
- **Status reason phrases**: ~2.7 ns per lookup across a set of six status codes, no allocation.
- **Method lookup**: case-insensitive name to enum in ~21.7 ns.

### Server Routing & Dispatch
Measured against a 10-route table mixing static, `{param}`, and typed `{id:int}` routes.
- **Static match**: ~1.24 µs (~806,000 ops/sec).
- **Parameter extraction**: ~1.25 µs, essentially the same cost as a static match - segment splitting is cheap next to route selection.
- **Full dispatch**: ~1.26 µs, so middleware stepping and response construction add only ~20 ns over a bare match.
- **Typed parameter match**: ~1.54 µs, the cost of integer conversion on top of a normal match.
- **Miss (404)**: ~2.00 µs; a miss is more expensive than a hit because every candidate is tried before falling through.
- **URL generation**: ~84 ns.

### Serialization, Feeds & Live Reload
- **JSON stringify**: ~276 ns (~3.6 million ops/sec) for a 6-field struct.
- **JSON parse**: ~344 ns (~2.9 million ops/sec) into a typed Zig struct.
- **JSON Feed parse**: ~4.06 µs for a 3-item feed on `std.json`. Feed documents go through `std.json` rather than a Tree-sitter grammar, so the whole parse is one allocator-backed pass instead of a syntax tree plus a manual tree walk.
- **Live-reload injection**: ~454 ns to append the SSE client script to an HTML page, idempotently, before `</body>`.

### Authentication
- **Basic auth encode**: ~25.6 ns (~39 million ops/sec).
- **Basic auth decode**: ~24.0 ns (~42 million ops/sec).
- **Bearer token parse**: ~11.0 ns (~91 million ops/sec).

### Compression & Decompression (1 KiB JSON payload)
- **Gzip compress**: ~76.5 µs (~13,000 ops/sec).
- **Gzip decompress**: ~11.2 µs (~89,000 ops/sec).
- **Deflate compress**: ~50.8 µs (~19,700 ops/sec).
- **Deflate decompress**: ~6.7 µs (~150,000 ops/sec).

Compression is ~7x more expensive than decompression, which is the usual shape for these codecs and the reason the client negotiates encoding once per connection instead of per response.

### Web & Document Parsing
- **HTML parse**: ~19.2 µs for a small document, Tree-sitter tokenisation plus DOM construction.
- **Template parse**: ~2.90 µs.
- **Template render**: ~1.53 µs, faster than parsing because the AST is cached and reused.
- **Template incremental reparse**: ~20.6 µs when the source is unchanged; this is the same-work comparison, and it shows the incremental path is not yet cheaper than a fresh parse on identical input.
- **Watcher scan**: ~1.15 ms for a full stat-walk of the template tree. The walk prunes ignored directories, so this cost is proportional to the files you actually watch, not to the repository around them.
- **Watcher dependency graph**: ~3.9 µs to resolve the affected set across 64 edges.

### Concurrency & DNS Caching
- **Bounded MPMC queue**: push then pop in ~42.8 ns (~23 million ops/sec).
- **Worker pool submit**: ~219 ns (~4.6 million ops/sec).
- **DNS cache hit**: ~55.0 ns (~18 million ops/sec) for a cached hostname, including the returned-address list allocation.

### Protocol Primitives (HTTP/2, HPACK, QUIC)
- **HTTP/2 frame header**: serialize plus parse of a 9-byte header in ~1.14 ns (~874 million ops/sec).
- **HPACK integer encode**: ~0.91 ns; **decode**: ~1.50 ns.
- **QUIC varint encode**: ~1.82 ns, **decode**: ~1.78 ns, both covering all four widths (1, 2, 4, and 8 byte encodings).

These are the cheapest operations in the suite, as expected: fixed-size header arithmetic with no branching on content.

### TLS
- **Record seal**: ChaCha20-Poly1305 AEAD seal of a 1 KiB record in ~1.62 µs (~619,000 ops/sec).
- **Certificate parse**: PEM decode plus DER parse of a P-256 chain in ~1.07 µs (~939,000 ops/sec).
- **Full handshake**: ~4.35 ms per handshake over loopback (~230/sec).
- **Resumed handshake**: ~2.94 ms per handshake (~339/sec), about 32% faster than a full handshake. The gap is narrower than TLS 1.3 0-RTT would suggest because the benchmark measures a full TCP connect and a PSK resumption over loopback, where connection setup and record-layer work dominate rather than key agreement.

### End-to-End Loopback Requests
- **HTTP/1.1 keep-alive GET** (`client_server_get`): ~387.8 µs per request, ~2,578 req/sec, between a live `httpx.Client` and a live `httpx.Server` on `127.0.0.1`, single-threaded and synchronous.
- **HTTP/2 pooled GET** (`h2_pooled_get`): ~55.9 µs, ~17,891 req/sec. One h2c connection is reused, so a request costs a frame exchange instead of a new connection - roughly 7x the HTTP/1.1 figure.
- **HTTP/3 GET** (`h3_get`): ~205.9 ms per request, ~4 req/sec, because each operation performs a fresh QUIC plus TLS 1.3 handshake rather than reusing a session. This is a deliberate worst case, not a steady-state HTTP/3 number.

---

## 4. How to Reproduce

From the root of the repository:

```bash
zig build bench
```

The benchmark executable is compiled with `-OReleaseFast` as configured in `build.zig`, so debug assertions do not distort the timings. The run prints its own environment header and ends with the Markdown table reproduced above.

Every benchmark runs on `127.0.0.1` or in-process; the suite requires no network access and no external tools.
