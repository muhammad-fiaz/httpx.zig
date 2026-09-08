---
title: Benchmarks & Performance
description: Comprehensive performance benchmarks for HTTPX covering core parsing, routing, serialization, compression, concurrency, DNS, protocols, and end-to-end client/server throughput.
---

# Benchmarks & Performance

HTTPX includes a dedicated in-tree benchmark suite (`bench/main.zig`) measuring real-world performance across every major subsystem. The benchmark suite uses native Zig 0.16.0 timing facilities (`std.Io.Timestamp`) and evaluates both microbenchmarks and end-to-end loopback client/server request performance.

> [!NOTE]
> All measurements in this report were produced directly by running `zig build bench` on **2026-09-07**. HTTPX never publishes estimated or fabricated numbers.

---

## 1. Test Environment

| Property | Value |
| :--- | :--- |
| **HTTPX Version** | `0.2.0` |
| **Zig Version** | `0.16.0` (stable) |
| **Optimization Mode** | `ReleaseFast` |
| **Target Architecture** | `x86_64` |
| **Operating System** | Windows 10+ (`x86_64-windows`) |
| **Benchmark Harness** | `bench/main.zig` via `zig build bench` |
| **Measurement Date** | `2026-09-07` |

---

## 2. Benchmark Summary

The following table summarizes representative performance measurements across all 28 benchmark targets. Each test runs 5 independent rounds with thousands to millions of iterations per round following warm-up discard:

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

---

## 3. Detailed Subsystem Analysis

### Core Operations & HTTP/1.1 Parsing
- **Zero-Copy Parser**: `http1_request_head` parses an entire HTTP request line in ~23.8 ns (~42 million ops/sec) by operating directly on borrowed socket slices without intermediary heap allocations.
- **Header Parsing**: `http1_header_block` parses an entire 5-header block in ~224 ns (~4.45 million ops/sec).
- **URI Parser**: Full RFC 3986 URL parsing with host, port, path, query, and fragment completes in ~34.3 ns (~29.1 million ops/sec).
- **Status & Method Dispatch**: Enum conversion and static phrase table lookups execute in ~1 ns to ~10 ns.

### Server Routing & Dispatch
- **Static Route Matching**: Exact path matching (`/api/v1/health`) against a 10-route table completes in ~1.01 µs (~988,000 ops/sec).
- **Dynamic Parameter Extraction**: Extracting parameters (`/users/:id/profile`) executes in ~1.10 µs (~912,000 ops/sec).
- **Full Dispatch**: Context setup, middleware stepping, and response generation together execute in ~1.10 µs.

### Serialization & Authentication
- **JSON Serialization**: Struct-to-JSON serialization completes in ~293 ns (~3.41 million ops/sec).
- **JSON Deserialization**: Typed deserialization into a native Zig struct completes in ~441 ns (~2.26 million ops/sec).
- **Authentication**: Base64 Basic auth encoding runs at ~18.2 million ops/sec; decoding runs at ~37.8 million ops/sec. Bearer token extraction takes ~8.1 ns (> 122 million ops/sec).

### Compression & Decompression (1 KiB JSON Payload)
- **Gzip Compression**: Compresses a 1,024-byte payload in ~68.6 µs (~14,500 ops/sec).
- **Gzip Decompression**: Decompresses a Gzip stream in ~8.8 µs (~113,600 ops/sec).
- **Deflate Compression**: Compresses in ~67.6 µs (~14,700 ops/sec).
- **Deflate Decompression**: Decompresses in ~8.1 µs (~123,000 ops/sec).

### Concurrency & DNS Caching
- **Bounded MPMC Queue**: Multi-producer multi-consumer push/pop takes ~68.8 ns (> 14.5 million ops/sec).
- **Worker Pool Submit**: Enqueueing tasks into `WorkerPool` worker threads takes ~206 ns (~4.84 million ops/sec).
- **DNS Cache**: Resolving a cached hostname via the thread-safe LRU cache executes in ~68.9 ns (~14.49 million ops/sec).

### Protocol Primitives (HTTP/2 & HTTP/3 / QUIC)
- **HTTP/2 Frame Headers**: Serializing and deserializing 9-byte frame headers takes ~1.19 ns (> 840 million ops/sec).
- **HPACK Integers**: Prefix integer encoding and decoding execute in ~1.02 ns to ~1.53 ns.
- **QUIC Variable-Length Integers**: RFC 9000 varint encoding executes in ~0.91 ns (> 1 billion ops/sec); decoding executes in ~1.15 ns (> 869 million ops/sec).

### End-to-End Loopback Requests (`client_server_get`)
- **Real Loopback Round-Trip**: Measures a complete HTTP/1.1 keep-alive GET request between a live `httpx.Client` and a live `httpx.Server` over `127.0.0.1`.
- **Latency**: 376.20 µs average round-trip latency per request.
- **Throughput**: 2,658 requests/sec on single-threaded synchronous loopback.

---

## 4. How to Reproduce

Run the benchmark suite locally from the root of the repository:

```bash
# Build and execute benchmarks in ReleaseFast mode:
zig build bench
```

The benchmark binary compiles using `-OReleaseFast` as configured in `build.zig`, ensuring production optimization without debug assertions distorting execution speeds.
