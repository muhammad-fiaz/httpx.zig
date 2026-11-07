<div align="center">
<img src="https://github.com/user-attachments/assets/ae3e1cc2-41f8-4326-b757-c9afcf6c8fea" alt="httpx.zig logo" width="400" />

<a href="https://muhammad-fiaz.github.io/httpx.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/httpx.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/httpx.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/httpx.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/httpx.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/httpx.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/github-code-scanning/codeql"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/github-code-scanning/codeql/badge.svg" alt="CodeQL"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/httpx.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/muhammad-fiaz/httpx.zig/"><img src="https://hits.sh/muhammad-fiaz/httpx.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>A Fast, High-Performance HTTP Client and Server Library for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/httpx.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/api/client">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`httpx.zig` is a modern, high-performance HTTP library for Zig, providing everything needed to build fast and reliable networked applications, including HTTP clients, servers, APIs, web services, reverse proxies, and full-stack websites.


> [!TIP]
> If you build with httpx.zig, make sure to give it a star ⭐.

## Why Use httpx.zig?

**One native Zig library for HTTP, networking, and web applications.**

- **HTTP client and server:** HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 with connection pooling, streaming, lifecycle management, and configurable timeouts.
- **TLS and secure transport:** TLS 1.2/1.3, ALPN, certificate and hostname verification, custom trust stores, mutual TLS, session resumption, HTTP/2 over TLS, HTTP/3 over QUIC, and FTP/FTPS.
- **Networking and proxies:** DNS resolution and TTL caching, connectivity checks, HTTP proxies, SOCKS4/4a, SOCKS5/SOCKS5h, remote DNS resolution, and cross-platform TCP/UDP networking.
- **File transfers and multipart:** Progress-aware downloads, resumable transfers, atomic updates, existing-file policies, size and checksum verification, multipart forms, and bounded streaming uploads.
- **Built-in web framework:** High-performance routing, typed parameters, route groups, mounts, named routes, reverse routing, 404/405 handling, middleware, CORS, security headers, CSRF protection, rate limiting, health checks, and error recovery.
- **REST and OpenAPI:** Typed REST handlers, OpenAPI 3.1 generation, and locally served Swagger UI, ReDoc, Scalar, and GraphiQL assets without external CDNs.
- **Web application capabilities:** GraphQL, static files, ETags, SPA fallback, sessions, WebSockets, Server-Sent Events, templates, and multipart request parsing.
- **Jinja templating:** Template inheritance, blocks, includes, loops, conditionals, filters, macros, call blocks, caching, and live-reload integration.
- **Parsing and compression:** HTML/XML DOM parsing, CSS selectors, RSS/Atom/JSON feeds, robots.txt, sitemaps, gzip, deflate, Brotli, Zstandard, MIME detection, and content negotiation.
- **Observability and development tools:** Prometheus metrics, metric snapshots, structured logging, request events, native file watching, CSS hot reload, and application reload workflows.
- **Explicit resource management:** Allocator and `std.Io` integration, deterministic cleanup, bounded concurrency, and thread-based server lifecycle management.

> [!NOTE]
> httpx.zig is actively evolving, and breaking API or behavioral changes may occur between releases. If you're using an older version, consider upgrading and review the release notes and documentation before migrating.
>
> **Contributions are welcome!** Bug reports, feature suggestions, documentation improvements, and pull requests are appreciated.

---

<details>
<summary><strong>Similar Zig Projects</strong> (click to expand)</summary>

- For **environment variables and `.env` parsing**, check out [env.zig](https://github.com/muhammad-fiaz/env.zig).
- For **TUI (Terminal User Interface)** support, check out [tui.zig](https://github.com/muhammad-fiaz/tui.zig).
- For **ZON file format** support, check out [zon.zig](https://github.com/muhammad-fiaz/zon.zig).
- For **spinners, loading indicators, and progress bars**, check out [loaders.zig](https://github.com/muhammad-fiaz/loaders.zig).
- For **terminal colors and text styling**, check out [tint.zig](https://github.com/muhammad-fiaz/tint.zig).
- For **Model Context Protocol (MCP)** support, check out [mcp.zig](https://github.com/muhammad-fiaz/mcp.zig).
- For **API framework** support, check out [api.zig](https://github.com/muhammad-fiaz/api.zig).
- For **web framework** support, check out [zix](https://github.com/muhammad-fiaz/zix).
- For **archive handling and compression**, check out [archive.zig](https://github.com/muhammad-fiaz/archive.zig).
- For **compression file formats**, check out [zigx](https://github.com/muhammad-fiaz/zigx).
- For **CUDA** support, check out [cuda.zig](https://github.com/muhammad-fiaz/cuda.zig).
- For **simplified `build.zig` configuration**, check out [buildx.zig](https://github.com/muhammad-fiaz/buildx.zig).
- For **SQLite with a Zig-native implementation**, check out [sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig).
- For **file downloading**, check out [downloader.zig](https://github.com/muhammad-fiaz/downloader.zig).
- For **update checking and automatic updates**, check out [updater.zig](https://github.com/muhammad-fiaz/updater.zig).
- For **numerical computing**, check out [num.zig](https://github.com/muhammad-fiaz/num.zig).
- For **logging**, check out [logly.zig](https://github.com/muhammad-fiaz/logly.zig).
- For **data validation and serialization**, check out [zigantic](https://github.com/muhammad-fiaz/zigantic).
- For **UUID** support, check out [uuid.zig](https://github.com/muhammad-fiaz/uuid.zig).
- For **key-value database** support, check out [zkv.zig](https://github.com/muhammad-fiaz/zkv.zig).
- For **terminal colors and text styling**, check out [hint.zig](https://github.com/muhammad-fiaz/hint.zig).
- For **Brotli compression**, check out [brotli.zig](https://github.com/muhammad-fiaz/brotli.zig).
- For **Zstandard (Zstd) compression**, check out [zstd.zig](https://github.com/muhammad-fiaz/zstd.zig).
- For **Tree-sitter** integration, check out [tree-sitter.zig](https://github.com/muhammad-fiaz/tree-sitter.zig).
- For **regular expressions**, check out [regex.zig](https://github.com/muhammad-fiaz/regex.zig).

</details>

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Protocol Support** | HTTP/1.0, HTTP/1.1, and HTTP/2 client/server runtimes; HTTP/3 client/server runtime over QUIC/TLS 1.3. QUIC includes ACK tracking, PTO/loss recovery, NewReno congestion control, flow control, transport parameters, 0-RTT resumption, Retry/token validation, v1/v2 version negotiation, and 1-RTT key updates. HTTP/3 still has no HelloRetryRequest handling or connection migration; the high-level client pools HTTP/3 connections for sequential reuse and does not multiplex concurrent requests over one connection. |
| **Header Compression** | HPACK (RFC 7541) for HTTP/2; QPACK (RFC 9204) for HTTP/3 with static and dynamic table management. |
| **Response Compression** | Automatic `Accept-Encoding` negotiation and on-the-fly compression for zstd, Brotli, gzip, and deflate across HTTP/1.1, HTTP/2, and HTTP/3, with configurable codec levels and input bounds. |
| **HTTP/2 & HTTP/3 ALPN** | Server-side ALPN negotiation during the TLS handshake with graceful HTTP/1.1 fallback; the native client offers ALPN too, so explicit `.http2` over TLS negotiates `h2` end to end, and `.http3` over QUIC negotiates `h3` end to end. |
| **Stream Multiplexing** | HTTP/2 and HTTP/3 stream state machines with flow control (WINDOW_UPDATE / MAX_STREAM_DATA), SETTINGS enforcement, GOAWAY/RST_STREAM, and trailers. The HTTP/2 server keeps one state per concurrent stream; the high-level client serializes per pooled connection. |
| **Connection Pooling** | TCP keep-alive reuse, HTTP/2 and HTTP/3 connection pooling, transport-level stream multiplexing (the high-level client serializes per pooled connection), and TLS session resumption caching. |
| **Unified DOM & Web Parsing** | DOM parsing and inspection for HTML, XML, RSS/Atom/JSON feeds, robots.txt, sitemaps, and a documented CSS-selector subset with zero-leak arena architecture. |
| **Streaming Downloader** | Resumable chunked file downloader powered by `loaders.zig` progress bars, ETA calculation, and hash verification. |
| **Pattern-based Routing** | Intuitive server routing with typed parameters (`/users/{id:int}`), slugs, catch-alls, groups, mounting, named routes + reversing, 404/405 handling, and OpenAPI integration. |
| **Middleware Stack** | Built-in middleware for CORS, security headers (Helmet), automated CSRF protection, and recovery; rate limiting, server event callbacks, health endpoints, and CSRF token helpers. |
| **TLS/SSL** | Native TLS 1.3 server engine + native TLS 1.3 client (RFC 8446) plus TLS 1.2/1.3 via the std-based HTTPS/1.1 transport: server ALPN (RFC 7301) with HTTP/1.1 fallback, native client ALPN (`h2` for HTTP/2 over TLS, `h3` for HTTP/3 over QUIC), X25519MLKEM768/X25519 key exchange, ChaCha20-Poly1305/AES-128-GCM server record ciphers, X.509 parsing/verification (P-256 ECDSA server certs), system/custom trust stores, hostname checks, mutual TLS enforcement (required/optional client certificates, presented via high-level `.tls = .{ .clientCertPem, .clientKeyPem }`), TLS 1.3 PSK session resumption (`psk_dhe_ke` NST tickets) + HelloRetryRequest, and opt-in TLS 1.3 0-RTT early data with bounded server-side anti-replay cache (`ReplayCache`) and safe HTTP method policy. |
| **Static Files & SPA** | High-performance static file serving with ETag, cache control, conditional GET, MIME detection, and SPA HTML5 fallback. |
| **Interactive API Docs** | Auto-generated OpenAPI 3.1 specifications with embedded Swagger UI, ReDoc, Scalar, and GraphiQL interfaces. |
| **Streaming & Realtime** | Chunked transfer responses with optional trailers, Server-Sent Events (SSE), and WebSocket frame support. |
| **Conditional Requests** | ETag and Last-Modified static file serving with `If-None-Match` revalidation. |
| **DNS Resolution** | Resolution with caching and concurrent resolver coalescing. |
| **Cookie APIs** | Standalone RFC 6265 cookie jar plus per-request cookie and header helpers for client and server contexts. |
| **Security & Hardening** | Security headers (Helmet), automated CSRF middleware and token helpers, and CRLF injection defenses. |
| **Multipart Form Data** | RFC 2046 multipart encoder and parser for text fields and file parts with streaming disk-sink and bounded buffered support. |
| **FTP & FTPS** | FTP client and server with PASV/EPSV, directory listing, streaming uploads/downloads, and resumption; explicit FTPS (`AUTH TLS`/`PBSZ`/`PROT`) is supported. |
| **Concurrency & Workers** | Thread-safe bounded `httpx.concurrency.Pool` and concurrent request execution. |
| **Proxy Support** | Client-side HTTP forward proxy (CONNECT with `Proxy-Authorization` auth, `407` → `error.ProxyAuthRequired`) and SOCKS4/4a plus SOCKS5/SOCKS5h tunneling with remote-DNS delegation. |
| **Structured Logging** | Zero-allocation level-filtered structured logger supporting custom sinks and terminal formatting. |
| **Cross-Platform Sockets** | Robust non-blocking Windows socket handling with `WSAEWOULDBLOCK` retry, plus `MSG_NOSIGNAL` on POSIX. |
| **Observability & Metrics** | Prometheus text exposition (`/metrics`), live request/duration histograms, status counters, and zero-alloc snapshots. |
| **File Watcher & Live Reload** | Event-driven directory watching (`next() ?WatchEvent`, `changeCount()`) with bounded event queues, cross-platform notifications, and hot/warm reload. |

</details>


---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Contents

- [Why Use httpx.zig?](#why-use-httpxzig)
- [Prerequisites](#prerequisites)
- [Supported Platforms](#supported-platforms)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Performance](#performance)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

> [!IMPORTANT]
> **Zig 0.17.0 is required.** This project targets the stable Zig 0.17.0 release. Please use Zig 0.17.0 for all builds.

---

## Supported Platforms

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|----------|-----------------|-----------------|--------------|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | Yes |

### Cross-Compilation

```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows

# Build for macOS Apple Silicon from Linux
zig build -Dtarget=aarch64-macos

# Build for 32-bit Windows
zig build -Dtarget=x86-windows
```

</details>

---

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

<details>
<summary><strong>Zig Fetch (Latest Beta / Development Build)</strong> (click to expand)</summary>

Use this for the latest beta development build from the GitHub `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

</details>

<details>
<summary><strong>Method 3: Manual `build.zig.zon` Configuration</strong> (click to expand)</summary>

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.4.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

</details>

<details>
<summary><strong>Method 4: Local Source Checkout</strong> (click to expand)</summary>

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

To use a local checkout from another project:

```zig
.dependencies = .{
    .httpx = .{
        .path = "../httpx.zig",
    },
},
```

</details>

### Wire into `build.zig`

```zig
const httpx_dep = b.dependency("httpx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
```

## Quick Start

Simple HTTP client and server example with REST and GraphQL:

```zig
const std = @import("std");
const httpx = @import("httpx");

const User = struct { id: u64, name: []const u8 };
const CreateUser = struct { name: []const u8 };

const Scalar = httpx.graphql.Scalar;
const UserType = httpx.graphql.Type("User", .{
    .id = Scalar.id,
    .name = Scalar.string,
});

const resolvers = struct {
    fn me(ctx: *httpx.graphql.Context) !User {
        _ = ctx;
        return .{ .id = 1, .name = "alice" };
    }
};

const QueryRoot = httpx.graphql.Query(.{
    .me = .{ .type = UserType, .resolve = resolvers.me },
});

fn getUser(ctx: *httpx.router.Context) !httpx.Schema(User) {
    return httpx.Schema(User).ok(.{ .id = ctx.paramUint("id") orelse 1, .name = "alice" });
}

fn createUser(_: *httpx.router.Context, body: CreateUser) !httpx.Schema(User) {
    return httpx.Schema(User).created(.{ .id = 1, .name = body.name });
}

fn health(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok", .contentType = "text/plain; charset=utf-8" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs = .{},
    });
    defer server.deinit();
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    try server.get("/health", .{ .handler = health, .summary = "Health check" });
    try server.get("/users/{id:int}", .{ .handler = getUser, .summary = "Get user" });
    try server.post("/users", .{ .handler = createUser, .summary = "Create user" });
    try server.graphql(.{
        .query = QueryRoot,
        .types = &.{UserType},
        .endpoint = "/graphql",
    });

    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    var urlBuf: [512]u8 = undefined;
    const health_url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/health", .{port});
    var health_res = try client.get(health_url, .{});
    defer health_res.deinit();
    std.debug.print("GET /health -> {d}: {s}\n", .{ health_res.status, health_res.bytes() });

    const user_url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users/7", .{port});
    var user_res = try client.get(user_url, .{});
    defer user_res.deinit();
    std.debug.print("GET /users/7 -> {d}: {s}\n", .{ user_res.status, user_res.bytes() });

    const post_url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users", .{port});
    var post_res = try client.post(post_url, .{ .json = .{ .name = "bob" } });
    defer post_res.deinit();
    std.debug.print("POST /users -> {d}: {s}\n", .{ post_res.status, post_res.bytes() });

    const gql_url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/graphql", .{port});
    var gql_res = try client.graphql(gql_url, "{ me { id name } }", null, .{});
    defer gql_res.deinit();
    std.debug.print("POST /graphql -> {d}: {s}\n", .{ gql_res.status, gql_res.bytes() });
}
```

## Performance

Run the benchmarks with:

```bash
zig build bench
```

<details>
<summary><strong>Benchmarks</strong> (click to expand)</summary>


Benchmark target: `x86_64-windows`, `ReleaseFast`. Measurements recorded on November 7, 2026.

| Benchmark | Category | Average Latency | Throughput |
| :--- | :--- | ---: | ---: |
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
| `tls_resumed_handshake` | TLS | 2.65 ms/op | **377 ops/sec** |

For the full benchmark methodology, measurement details, and analysis, see [Benchmark Documentation](docs/reference/benchmarks.md).

**Note:** These are recorded measurements for the specified platform and build mode, not universal performance guarantees. Results may vary with hardware, compiler version, workload, and system configuration.

</details>

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.
