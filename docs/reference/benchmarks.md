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
| **HTTPX Version** | `0.2.2` |
| **Zig Version** | `0.17.0` |
| **Optimization Mode** | `ReleaseFast` |
| **Target Architecture** | `x86_64` |
| **Operating System** | Windows (`x86_64-windows`) |
| **Benchmark Harness** | `bench/main.zig` via `zig build bench` |
| **Measurement Date** | `2026-10-09` |

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

> [!NOTE]
> In this run `client_server_get` reported 6 failed iterations out of 8000 (the known loopback keep-alive reuse race described below), so its row is marked and its timings are not valid for the failed iterations. The run exited non-zero as designed.

---

## 3. Detailed Subsystem Analysis

### Core Operations & HTTP/1.1 Parsing
- **Zero-copy request head**: `http1_request_head` parses a full request line - method, target, version - in ~46.4 ns (~21.6 million ops/sec), operating directly on borrowed slices with no intermediate allocation.
- **Header block**: `http1_header_block` parses a 5-header block in ~292 ns (~3.4 million ops/sec).
- **URI**: full RFC 3986 parsing of scheme, host, port, path, query, and fragment in ~30.4 ns (~32.9 million ops/sec).
- **Status reason phrases**: ~3.2 ns per lookup across a set of six status codes, no allocation.
- **Method lookup**: case-insensitive name to enum in ~22.1 ns.

### Server Routing & Dispatch
Measured against a 10-route table mixing static, `{param}`, and typed `{id:int}` routes.
- **Static match**: ~300 ns (~3.3 million ops/sec).
- **Parameter extraction**: ~375 ns, segment splitting is cheap next to route selection.
- **Full dispatch**: ~304 ns, so middleware stepping and response construction add only a few nanoseconds over a bare match.
- **Typed parameter match**: ~390 ns, the cost of integer conversion on top of a normal match.
- **Miss (404)**: ~518 ns; a miss is more expensive than a hit because every candidate is tried before falling through.
- **URL generation**: ~124 ns.

### Serialization, Feeds & Live Reload
- **JSON stringify**: ~244 ns (~4.1 million ops/sec) for a 6-field struct.
- **JSON parse**: ~365 ns (~2.7 million ops/sec) into a typed Zig struct.
- **JSON Feed parse**: ~4.12 µs for a 3-item feed on `std.json`. Feed documents go through `std.json` rather than a Tree-sitter grammar, so the whole parse is one allocator-backed pass instead of a syntax tree plus a manual tree walk.
- **Live-reload injection**: ~230 ns to append the SSE client script to an HTML page, idempotently, before `</body>`.

### Authentication
- **Basic auth encode**: ~36.7 ns (~27 million ops/sec).
- **Basic auth decode**: ~14.7 ns (~68 million ops/sec).
- **Bearer token parse**: ~1.1 ns (~936 million ops/sec).

### Compression & Decompression (1 KiB JSON payload)
- **Gzip compress**: ~24.7 µs (~40,000 ops/sec).
- **Gzip decompress**: ~9.0 µs (~111,000 ops/sec).
- **Deflate compress**: ~19.7 µs (~50,800 ops/sec).
- **Deflate decompress**: ~7.6 µs (~131,500 ops/sec).

Compression is ~2.6x more expensive than decompression, which is the usual shape for these codecs and the reason the client negotiates encoding once per connection instead of per response.

### Web & Document Parsing
- **HTML parse**: ~22.7 µs for a small document, Tree-sitter tokenisation plus DOM construction.
- **Template parse**: ~2.80 µs.
- **Template render**: ~1.75 µs, faster than parsing because the AST is cached and reused.
- **Template incremental reparse**: ~24.6 µs when the source is unchanged; this is the same-work comparison, and it shows the incremental path is not yet cheaper than a fresh parse on identical input.
- **Watcher scan**: ~1.16 ms for a full stat-walk of the template tree. The walk prunes ignored directories, so this cost is proportional to the files you actually watch, not to the repository around them.
- **Watcher dependency graph**: ~3.9 µs to resolve the affected set across 64 edges.

### Concurrency & DNS Caching
- **Bounded MPMC queue**: push then pop in ~50.5 ns (~20 million ops/sec).
- **Worker pool submit**: ~238 ns (~4.2 million ops/sec).
- **DNS cache hit**: ~56.2 ns (~17.8 million ops/sec) for a cached hostname, including the returned-address list allocation.

### Protocol Primitives (HTTP/2, HPACK, QUIC)
- **HTTP/2 frame header**: serialize plus parse of a 9-byte header in ~1.05 ns (~954 million ops/sec).
- **HPACK integer encode**: ~1.43 ns; **decode**: ~4.12 ns.
- **QUIC varint encode**: ~1.54 ns, **decode**: ~1.57 ns, both covering all four widths (1, 2, 4, and 8 byte encodings).

These are the cheapest operations in the suite, as expected: fixed-size header arithmetic with no branching on content.

### TLS
- **Record seal**: ChaCha20-Poly1305 AEAD seal of a 1 KiB record in ~1.29 µs (~778,000 ops/sec).
- **Certificate parse**: PEM decode plus DER parse of a P-256 chain in ~1.04 µs (~962,000 ops/sec).
- **Full handshake**: ~3.40 ms per handshake over loopback (~294/sec).
- **Resumed handshake**: ~2.85 ms per handshake (~350/sec), about 16% faster than a full handshake. The gap is narrower than TLS 1.3 0-RTT would suggest because the benchmark measures a full TCP connect and a PSK resumption over loopback, where connection setup and record-layer work dominate rather than key agreement.

### End-to-End Loopback Requests
- **HTTP/1.1 keep-alive GET** (`client_server_get`): ~54.6 µs per request, ~18,310 req/sec, between a live `httpx.Client` and a live `httpx.server.Server` on `127.0.0.1`, single-threaded and synchronous. In the 2026-10-09 run this row reported 6 failed iterations out of 8000 (the keep-alive reuse race); see the note under the summary table.
- **HTTP/2 pooled GET** (`h2_pooled_get`): ~48.7 µs, ~20,524 req/sec. One h2c connection is reused, so a request costs a frame exchange instead of a new connection.
- **HTTP/3 GET** (`h3_get`): ~206.0 ms per request, ~4 req/sec, because each operation performs a fresh QUIC plus TLS 1.3 handshake rather than reusing a session. This is a deliberate worst case, not a steady-state HTTP/3 number.

---

## 4. How to Reproduce

From the root of the repository:

```bash
zig build bench
```

The benchmark executable is compiled with `-OReleaseFast` as configured in `build.zig`, so debug assertions do not distort the timings. The run prints its own environment header and ends with the Markdown table reproduced above.

Every benchmark runs on `127.0.0.1` or in-process; the suite requires no network access and no external tools.
