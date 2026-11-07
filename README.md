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

`httpx.zig` is a modern, high-performance HTTP library for Zig, providing everything needed to build fast and reliable networked applications, including HTTP clients, servers, APIs, web services, reverse proxies, and full-featured websites.


> [!TIP]
> If you build with httpx.zig, make sure to give it a star.

## Why Use httpx.zig?

**One native Zig library for HTTP, networking, and web applications.**

- **HTTP client and server:** HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 with connection pooling, streaming, lifecycle management, and configurable timeouts.
- **TLS and secure transport:** TLS 1.2/1.3, ALPN, certificate and hostname verification, custom trust stores, mutual TLS, session resumption, HTTP/2 over TLS, HTTP/3 over QUIC, and FTP/FTPS.
- **Networking and proxies:** DNS resolution and TTL caching, connectivity checks, HTTP proxies, SOCKS4/4a, SOCKS5/SOCKS5h, remote DNS resolution, and cross-platform TCP/UDP networking.
- **HTTP client API:** Typed JSON serialization and deserialization, headers, query parameters, cookies, Basic and Bearer authentication, retries, redirects, request configuration, batch operations, request builders, and response streaming.
- **File transfers and multipart:** Progress-aware downloads, resumable transfers, atomic updates, existing-file policies, size and checksum verification, multipart forms, and bounded streaming uploads.
- **Built-in web framework:** High-performance routing, typed parameters, route groups, mounts, named routes, reverse routing, 404/405 handling, middleware, CORS, security headers, CSRF protection, rate limiting, health checks, and error recovery.
- **REST and OpenAPI:** Typed REST handlers, OpenAPI 3.1 generation, and locally served Swagger UI, ReDoc, Scalar, and GraphiQL assets without external CDNs.
- **Web application capabilities:** GraphQL, static files, ETags, SPA fallback, sessions, WebSockets, Server-Sent Events, templates, and multipart request parsing.
- **Jinja templating:** Template inheritance, blocks, includes, loops, conditionals, filters, macros, call blocks, caching, and live-reload integration.
- **Parsing and compression:** HTML/XML DOM parsing, CSS selectors, RSS/Atom/JSON feeds, robots.txt, sitemaps, gzip, deflate, Brotli, Zstandard, MIME detection, and content negotiation.
- **Observability and development tools:** Prometheus metrics, metric snapshots, structured logging, request events, native file watching, CSS hot reload, and application reload workflows.
- **Explicit resource management:** Allocator and `std.Io` integration, deterministic cleanup, bounded concurrency, and thread-based server lifecycle management.

httpx.zig brings HTTP, networking, and web development together in one native Zig
library. Its design emphasizes a consistent API, explicit resource ownership,
efficient I/O, and modular implementation.


[**Explore the documentation**](./docs/) for installation, guides, API references,
examples, supported features, and migration instructions.
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
| **macOS** | Yes | Yes (Apple Silicon) | No |

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

**Previous Release (v0.2.3, Zig 0.17)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.3.tar.gz
```

> [!NOTE]
> **httpx.zig** requires Zig **0.17.0+**.
>
> For documentation matching older releases of `httpx.zig`, checkout that release's tag and generate local documentation using `zig build docs`, which emits native HTML documentation into `zig-out/docs/`.

### Method 2: Zig Fetch (Latest Development Build)

Use this for the latest development build from the `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.4.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

### Method 4: Local Source Checkout

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

### Wire into `build.zig`

```zig
const httpx_dep = b.dependency("httpx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
```

> [!NOTE]
> If you encounter `file exists in modules 'X' and 'X0'`, try removing `.target = target` and `.optimize = optimize` from your dependency options in the root `build.zig` and use `.{}` instead. This can help prevent duplicate module instances when multiple dependencies resolve the same module. See [Zig issue #36694](https://codeberg.org/ziglang/zig/issues/36694).

## Quick Start


`httpx.Server` serves the inbound side and `httpx.Client` handles outbound
calls; both are created with the same allocator and `std.Io` and configured
with a single `.{}` literal. The program below exercises the complete
surface — typed REST, a raw route, the GraphQL endpoint, every docs UI, and
the client verbs — and was verified end-to-end (every route returns HTTP 200).

```zig
const std = @import("std");
const httpx = @import("httpx");

// REST types: typed handlers encode/decode JSON and feed OpenAPI.
const User = struct { id: u64, name: []const u8 };
const CreateUser = struct { name: []const u8 };

// GraphQL type and resolver: explicit spec, same JSON engine as REST.
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

// Typed REST: JSON body decoding plus OpenAPI 3.1 generation.
fn getUser(ctx: *httpx.router.Context) !httpx.Schema(User) {
    return httpx.Schema(User).ok(.{ .id = ctx.paramUint("id") orelse 1, .name = "alice" });
}

fn createUser(_: *httpx.router.Context, body: CreateUser) !httpx.Schema(User) {
    return httpx.Schema(User).created(.{ .id = 1, .name = body.name });
}

// Raw route: plain Response, no schema derivation.
fn health(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok", .contentType = "text/plain; charset=utf-8" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // The server owns the listener, router, docs, and GraphQL mount; the
    // client handles every outbound call. Both take the same allocator/io.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0, // 0: OS picks a free port
    });
    defer server.deinit();
    var client = httpx.Client.init(allocator, io, .{ .timeoutMs = 10_000 });
    defer client.deinit();

    // Register routes before docs so the OpenAPI snapshot includes them.
    try server.get("/health", .{ .handler = health, .summary = "Health check", .tags = &.{"system"} });
    try server.get("/users/{id:int}", .{
        .handler = getUser,
        .summary = "Get user",
        .tags = &.{"users"},
        .params = &.{
            .{ .name = "id", .in = .path, .required = true, .schema = httpx.rest.schemaOf(u64) },
            .{ .name = "expand", .in = .query, .schema = httpx.rest.schemaOf(bool) },
        },
        .responses = &.{
            .{ .status = 200, .description = "User", .schema = httpx.rest.schemaOf(User) },
            .{ .status = 404, .description = "Not found" },
        },
    });
    try server.post("/users", .{
        .handler = createUser,
        .summary = "Create user",
        .tags = &.{"users"},
        .request = .{ .content = .json, .description = "User to create" },
    });

    // GraphQL endpoint; GraphiQL UI is served by the docs mount below.
    const graph_schema = httpx.graphql.Schema.init(allocator, io, .{
        .query = QueryRoot,
        .types = &.{UserType},
        .introspection = true,
    });
    try server.graphql(graph_schema, .{ .endpoint = "/graphql" });

    // Every bundled UI explicitly enabled; all assets embedded and offline.
    try server.docs(.{
        .enabled = true,
        .title = "Quick Start API",
        .version = httpx.version,
        .description = "REST, GraphQL, and OpenAPI in one app",
        .openapi = .{ .enabled = true, .route = "/openapi.json" },
        .swagger = .{
            .enabled = true,
            .route = "/docs",
            .title = "Swagger UI",
            .docExpansion = .full,
            .displayRequestDuration = true,
            .filter = true,
            .persistAuthorization = true,
        },
        .redoc = .{
            .enabled = true,
            .route = "/redoc",
            .title = "ReDoc",
            .hideDownloadButton = true,
            .requiredPropsFirst = true,
        },
        .scalar = .{
            .enabled = true,
            .route = "/scalar",
            .title = "Scalar API Reference",
            .theme = "default",
            .showSidebar = true,
        },
        .graphiql = .{
            .enabled = true,
            .route = "/graphiql",
            .graphqlEndpoint = "/graphql",
            .title = "GraphiQL IDE",
            .editorTheme = "vs-dark",
        },
    });

    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base);
    var url_buf: [512]u8 = undefined;

    // Client verbs reuse the same allocator/io as the server.
    const health_url = try std.fmt.bufPrint(&url_buf, "{s}/health", .{base});
    var health_res = try client.get(health_url, .{});
    defer health_res.deinit();
    std.debug.print("GET /health -> {d}: {s}\n", .{ health_res.status, health_res.bytes() });

    const user_url = try std.fmt.bufPrint(&url_buf, "{s}/users/7", .{base});
    var user_res = try client.get(user_url, .{});
    defer user_res.deinit();
    std.debug.print("GET /users/7 -> {d}: {s}\n", .{ user_res.status, user_res.bytes() });

    const post_url = try std.fmt.bufPrint(&url_buf, "{s}/users", .{base});
    var post_res = try client.post(post_url, .{ .json = .{ .name = "bob" } });
    defer post_res.deinit();
    std.debug.print("POST /users -> {d}: {s}\n", .{ post_res.status, post_res.bytes() });

    var req_res = try client.request(health_url, .{ .method = .GET });
    defer req_res.deinit();
    var fetch_res = try client.fetch(health_url, .{});
    defer fetch_res.deinit();

    // GraphQL over the same client.
    const gql_url = try std.fmt.bufPrint(&url_buf, "{s}/graphql", .{base});
    var gql_res = try client.graphql(gql_url, "{ me { id name } }", null, .{});
    defer gql_res.deinit();
    std.debug.print("POST /graphql -> {d}: {s}\n", .{ gql_res.status, gql_res.bytes() });

    // The server is now serving typed REST at /health and /users, GraphQL at
    // /graphql, the OpenAPI document at /openapi.json, and the docs UIs at
    // /docs (Swagger UI), /redoc (ReDoc), /scalar (Scalar), and /graphiql
    // (GraphiQL IDE) — open any of them in a browser.

    // Download and FTP reuse their initialized owners:
    // _ = try client.download(health_url, .{ .path = "downloads/health.txt" });
    // var ftp = try httpx.client.ftp.init(allocator, io, .{ .host = "ftp.example.com" });
    // defer ftp.deinit();
    // _ = try ftp.download(.{ .remotePath = "/pub/file.txt", .destinationPath = "downloads/file.txt" });
}
```

## Performance

<details>
<summary><strong>Benchmarks</strong> (click to expand)</summary>

Run the benchmarks with:

```bash
zig build bench
```

Benchmark target: `x86_64-windows`, `ReleaseFast`. Measurements recorded on October 2, 2026.

| Benchmark | Category | Average Latency | Throughput | Target |
| :--- | :--- | ---: | ---: | :--- |
| `headers_parse` | Core Operations | 257.49 ns/op | **3,883,591 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 35.65 ns/op | **28,046,635 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 2.23 ns/op | **449,147,518 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 19.74 ns/op | **50,650,119 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 24.58 ns/op | **40,687,786 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 263.30 ns/op | **3,797,967 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 1.02 µs/op | **977,952 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 1.06 µs/op | **944,143 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 1.03 µs/op | **970,782 ops/sec** | `x86_64-windows` |
| `router_typed_match` | Routing | 1.14 µs/op | **880,393 ops/sec** | `x86_64-windows` |
| `router_miss_404` | Routing | 1.81 µs/op | **550,989 ops/sec** | `x86_64-windows` |
| `router_reverse` | Routing | 68.65 ns/op | **14,565,687 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 245.93 ns/op | **4,066,174 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 312.18 ns/op | **3,203,298 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 24.20 ns/op | **41,328,974 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 23.31 ns/op | **42,897,466 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 7.82 ns/op | **127,813,494 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 53.11 µs/op | **18,830 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 6.64 µs/op | **150,626 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 63.54 µs/op | **15,737 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 6.48 µs/op | **154,405 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 20.13 µs/op | **49,668 ops/sec** | `x86_64-windows` |
| `template_parse` | Parsing | 2.90 µs/op | **345,360 ops/sec** | `x86_64-windows` |
| `template_render` | Parsing | 1.46 µs/op | **683,819 ops/sec** | `x86_64-windows` |
| `template_incremental` | Parsing | 22.94 µs/op | **43,597 ops/sec** | `x86_64-windows` |
| `json_feed_parse` | Parsing | 3.78 µs/op | **264,404 ops/sec** | `x86_64-windows` |
| `live_reload_inject` | Parsing | 230.33 ns/op | **4,341,596 ops/sec** | `x86_64-windows` |
| `watcher_scan` | Watcher | 1.14 ms/op | **879 ops/sec** | `x86_64-windows` |
| `watcher_deps` | Watcher | 4.21 µs/op | **237,375 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 228.54 ns/op | **4,375,553 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 37.93 ns/op | **26,365,676 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 48.49 ns/op | **20,623,531 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.09 ns/op | **921,523,093 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 1.04 ns/op | **963,131,332 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 1.42 ns/op | **704,508,147 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 1.58 ns/op | **632,739,191 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.59 ns/op | **627,817,330 ops/sec** | `x86_64-windows` |
| `tls_record_seal` | TLS | 1.62 µs/op | **619,051 ops/sec** | `x86_64-windows` |
| `tls_cert_parse` | TLS | 1.07 µs/op | **938,620 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 387.84 µs/op | **2,578 req/sec** | `x86_64-windows` |
| `h2_pooled_get` | Network | 55.89 µs/op | **17,891 req/sec** | `x86_64-windows` |
| `h3_get` | Network | 205.89 ms/op | **4 req/sec** | `x86_64-windows` |
| `tls_full_handshake` | TLS | 4.35 ms/op | **230 ops/sec** | `x86_64-windows` |
| `tls_resumed_handshake` | TLS | 2.94 ms/op | **339 ops/sec** | `x86_64-windows` |

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

<details>
<summary><strong>Project Structure</strong> (click to expand)</summary>

```text
httpx.zig/
├── src/
│   ├── httpx.zig              # Public API exports
│   ├── client/                # HTTP client, requests, pooling, cookies, downloads
│   ├── server/                # HTTP server implementation
│   ├── web/                   # Router, REST, GraphQL, middleware, docs, WebSockets
│   ├── protocols/             # HTTP/1, HTTP/2, HTTP/3, QUIC, TLS, FTP
│   ├── net/                   # DNS, proxy, connectivity, address resolution
│   ├── sockets/               # TCP, UDP, and system socket wrappers
│   ├── parsing/               # HTML/XML DOM, selectors, feeds, robots, sitemaps
│   ├── compression/           # Compression implementations
│   ├── concurrency/           # Pools and bounded concurrent work
│   ├── common/                # Shared methods, headers, URI, and I/O types
│   ├── utils/                 # MIME and filesystem utilities
│   └── assets/                # Embedded web assets
├── examples/                  # Runnable client, server, protocol, and web examples
├── bench/
│   └── main.zig               # Benchmarks
├── docs/                      # VitePress documentation
├── build.zig                  # Build configuration
├── build.zig.zon              # Package metadata
├── README.md
├── SECURITY.md
├── LICENSE
└── CONTRIBUTING.md
```

</details>

## License

MIT License - see [LICENSE](LICENSE) for details.
