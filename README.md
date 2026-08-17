<div align="center">
<img src="https://github.com/user-attachments/assets/ae3e1cc2-41f8-4326-b757-c9afcf6c8fea" alt="httpx.zig logo" width="400" />

<a href="https://muhammad-fiaz.github.io/httpx.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig" alt="Zig Version"></a>
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

<p><em>A production-ready, high-performance HTTP client and server library for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/httpx.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/api/client">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`httpx.zig` is a modern, high-performance HTTP library for Zig, providing everything needed to build fast and reliable networked applications, including HTTP clients, servers, APIs, web services, reverse proxies, and full-featured websites.

> [!TIP]
> If you build with httpx.zig, make sure to give it a star. ⭐


> [!NOTE]
> **Project maturity:** This project aims to be production-ready and is actively maintained. It is still a new project and not yet widely adopted. Feel free to use it in your projects.
>
> **Custom HTTP/2, HTTP/3, and TLS implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, or TLS/ALPN support.
> httpx.zig implements these protocols **entirely from scratch**, including:
> - **TLS 1.2 and 1.3** with full handshake support (RFC 5246 / RFC 8446) — key exchange: X25519 (TLS 1.2/1.3); AEAD cipher suites: ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM; ALPN negotiation (RFC 7301) for automatic HTTP/2 and HTTP/3 protocol selection with HTTP/1.1 fallback; handshake message encryption (TLS 1.3); X.509 certificate parsing and verification (client-side); custom record-layer encryption/decryption
> - **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
> - **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 7540)
> - **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
> - **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, version negotiation, and transport parameters
> - **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
> - **Interop note:** strict TLS-in-QUIC server negotiation expectations may vary by endpoint deployment

**Related Zig projects:**

- For **env.zig** (.env parsing), check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **ZON file format** support, check out **[zon.zig](https://github.com/muhammad-fiaz/zon.zig)**.
- For **spinners/loading/progress bar** support, check out **[loaders.zig](https://github.com/muhammad-fiaz/loaders.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.
- For **args parsing** support, check out **[args.zig](https://github.com/muhammad-fiaz/args.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **CUDA** support, check out **[cuda.zig](https://github.com/muhammad-fiaz/cuda.zig)**.
- For **Simplified build.zig config** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.
- For **SQLite** support, check out **[sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig)**.
- For **file downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
- For **UUID** support, check out **[uuid.zig](https://github.com/muhammad-fiaz/uuid.zig)**.
- For **key-value database** support, check out **[zkv.zig](https://github.com/muhammad-fiaz/zkv.zig)**.
- For **terminal color & text styles** support, check out **[hint.zig](https://github.com/muhammad-fiaz/hint.zig)**.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description | Documentation |
|---------|-------------|---------------|
| **Protocol Support** | Full runtime support for **HTTP/1.0**, **HTTP/1.1**, **HTTP/2**, and **HTTP/3** in high-level client/server APIs, plus low-level protocol primitives. | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Header Compression** | HPACK (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2; QPACK (RFC 9204) with decoder/encoder stream instructions for HTTP/3. | https://muhammad-fiaz.github.io/httpx.zig/guide/http2 |
| **HTTP/2 ALPN** | Automatic protocol negotiation during TLS handshake with HTTP/1.1 fallback. | https://muhammad-fiaz.github.io/httpx.zig/guide/http2 |
| **Stream Multiplexing** | HTTP/2 stream state machine with flow control, SETTINGS enforcement, GOAWAY/RST_STREAM, and trailer support. | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Connection Pooling** | Automatic reuse of TCP connections (including HTTP/2 connections) with keep-alive and health checking. | https://muhammad-fiaz.github.io/httpx.zig/guide/pooling |
| **Pool Introspection** | Built-in connection pool stats and per-host connection counts. | https://muhammad-fiaz.github.io/httpx.zig/api/pool |
| **Pattern-based Routing** | Intuitive server routing with dynamic path parameters and groups. | https://muhammad-fiaz.github.io/httpx.zig/guide/routing |
| **Port Conflict Handling** | Explicit startup strategy to fail fast or auto-increment to the next free port. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Middleware Stack** | Built-in middleware for CORS (comptime-zero-alloc), Compression (gzip/deflate/brotli/zstd), Timeout enforcement, Rate Limiting (with eviction and thread safety), Logging, Auth, Helmet, CSRF Protection, Reverse Proxy (with SSRF protection), Body Parsing, Request ID, and Health/Readiness probes. | https://muhammad-fiaz.github.io/httpx.zig/guide/middleware |
| **CSRF Protection** | Double-submit cookie pattern middleware for state-changing requests (POST/PUT/PATCH/DELETE). Generates random tokens, validates via header or form field. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **SSRF Protection** | Built into reverse proxy middleware. Blocks requests to private/internal IP ranges (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, link-local, localhost). Returns 403 Forbidden. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **Server Connection Limiting** | Atomic connection counter with configurable `max_connections`. Rejects new connections at capacity with clean socket close. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Client Request Size Limiting** | Configurable `max_request_size` on `ClientConfig` (default 10 MB). Raises `RequestTooLarge` error, excluded from retry logic. | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **Pre-Route and Global Handlers** | `preRoute(...)` hooks and `global(...)` fallback handlers for complete request lifecycle control. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Unified Any-Method Routing** | `any(path, handler)` to register all standard HTTP methods on one endpoint. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Concurrency** | Parallel request patterns (`race`, `all`, `any`, `allSettled`, `first`, `fastest`, `settled`) and async task execution with `BatchBuilder`. | https://muhammad-fiaz.github.io/httpx.zig/guide/concurrency |
| **Socket APIs** | Cross-platform TCP/UDP socket helpers, listener wrappers, and TLS stream adapters. | https://muhammad-fiaz.github.io/httpx.zig/api/net |
| **Proxy Support** | Client-side HTTP forward proxy routing, SOCKS5h tunneling, and server-side reverse proxy middleware with SSRF protection. | https://muhammad-fiaz.github.io/httpx.zig/examples/proxy-example |
| **Interceptors** | Global hooks to modify requests and responses (e.g., Auth injection). | https://muhammad-fiaz.github.io/httpx.zig/guide/interceptors |
| **Logging Hooks** | Server log callbacks plus logger middleware customization for structured output. Internal logging uses tint.zig for colored output; configurable via `log_level` and `log_fn`. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **Smart Retries** | Configurable retry policies with exponential backoff. | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **Cross-Platform Sockets** | Robust Windows socket handling with `WSAEWOULDBLOCK` retry via `select()`, plus `MSG_NOSIGNAL` on Linux/macOS to prevent SIGPIPE crashes. | https://muhammad-fiaz.github.io/httpx.zig/api/net |
| **Config Builder Helpers** | Chainable optional customization helpers for `ClientConfig` and `RequestOptions` (defaults remain implicit). | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **JSON and HTML** | Helpers for easy JSON serialization and HTML response generation. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **Zero-Copy JSON** | Type-safe JSON methods (`getJson`, `postJsonAndParse`, `Response.json`, `ctx.jsonBody`) with zero-copy borrowed parsing — no arena required. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **Core Convenience APIs** | Request query-param helpers and response constructors for redirect/text/json. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **TLS/SSL** | Full TLS 1.2 and 1.3 with ALPN (RFC 7301), X25519 key exchange, AEAD ciphers (ChaCha20-Poly1305, AES-128/256-GCM), handshake encryption, X.509 certificate parsing (client-side), PEM cert/key loading for servers, and custom record-layer encryption/decryption. | https://muhammad-fiaz.github.io/httpx.zig/api/tls |
| **Static Files** | Efficient static file serving with ETag, cache control, conditional GET, and MIME type detection. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Streaming and Realtime** | Chunked transfer responses with optional trailers and SSE response helpers. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Streaming Compression** | `StreamingCompressor` and `StreamingDecompressor` for chunked gzip/deflate/brotli/zstd without buffering entire payloads. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **HTTP Caching** | `CacheControl` header parsing, `HttpCache` (LRU in-memory with TTL), `ConditionalGet` (ETag/If-None-Match), and thread-safe cache operations. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **Buffer Pool** | `BufferPool` with slot-based ownership tracking, acquire/release semantics, and detection of foreign/double-release buffers. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **DNS Resolution** | `resolveAddress`, `resolveAllAddresses`, `parseHostAndPort`, `parseAndResolveAddress`, `isIpAddress`, `isIp4Address`, `isIp6Address` helpers. | https://muhammad-fiaz.github.io/httpx.zig/api/dns |
| **Server-Sent Events** | `SseEvent` type and `parseSseStream` helper for SSE client parsing. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **Debug System** | Structured debug logging with `entry`/`exit`/`log`/`detail` calls, configurable via `debug.enabled` flag. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **HTTP/3 Flow Control** | MAX_DATA and MAX_STREAM_DATA frame handling with connection-level and per-stream flow control windows. | https://muhammad-fiaz.github.io/httpx.zig/examples/http3-advanced |
| **Stream Cancellation** | RESET_STREAM and STOP_SENDING frames for graceful HTTP/3 stream teardown without connection disruption. | https://muhammad-fiaz.github.io/httpx.zig/examples/http3-advanced |
| **Cookie APIs** | First-class request/response cookie helpers for both client and server contexts. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Security** | Security headers (Helmet: X-Content-Type-Options, X-Frame-Options, X-XSS-Protection, HSTS), CSRF protection, SSRF protection in reverse proxy, and safe defaults. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **Minimal Dependencies** | Pure Zig core implementation for maximum portability. Compression uses bundled brotli and zstd packages. | https://muhammad-fiaz.github.io/httpx.zig/guide/installation |
| **Shared Common Helpers** | Reusable query/cookie helpers plus MIME resolution with explicit fallback and external mapping support. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |
| **WebSockets** | RFC 6455 upgrade checks, handshake accept key computations, and frame encoding/decoding. | https://muhammad-fiaz.github.io/httpx.zig/examples/websocket-example |
| **Multipart Form Data** | RFC 2046 multipart body builder (`addFile`, `addFileChunked`) and parser for text fields and large file uploads. Windows-safe: each `winsock.send()` is capped at 64 KB to prevent upload hangs (fix for issue [#26](https://github.com/muhammad-fiaz/httpx.zig/issues/26)). | https://muhammad-fiaz.github.io/httpx.zig/examples/multipart-example |
| **Session Management** | TTL-based secure in-memory session store and cookie integration. | https://muhammad-fiaz.github.io/httpx.zig/examples/session-example |
| **Observability & Metrics** | Real-time traffic counters, per-class status tracking, and latency measuring. | https://muhammad-fiaz.github.io/httpx.zig/examples/metrics-example |
| **Unix Domain Sockets** | High-performance client-server IPC over AF_UNIX sockets. Available on Linux, macOS, and Windows 10 build 17061+ (requires Developer Mode). | https://muhammad-fiaz.github.io/httpx.zig/examples/unix-socket-example |
| **Health Checks** | Built-in liveness and readiness probe middlewares for deployments. | https://muhammad-fiaz.github.io/httpx.zig/examples/health-check-example |

</details>

----

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `httpx.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.16.0** (recommended) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

> [!IMPORTANT]
> **Zig 0.16.0 is required.** This project currently targets Zig 0.16.0 (stable). Zig 0.17.0 is in development (dev branch, not yet a stable release) and introduces several minor breaking changes from 0.16.0. Migration to 0.17.0 will happen once it is officially released as a stable version. Please use Zig 0.16.0 for all builds.

---

## Supported Platforms

`httpx.zig` is validated on these architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|----------|-----------------|-----------------|--------------|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | No |

### Cross-Compilation

Zig makes cross-compilation easy. Build for any target from any host:

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

**Latest Release (v0.1.6)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.6.tar.gz
```

**Previous Stable Release (v0.1.5)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.5.tar.gz
```

> [!WARNING]
> Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.16.0+** with **httpx.zig v0.1.6**.

### Method 2: Zig Fetch (Main Branch)

Use the latest development version from the `main` branch.

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

Add the dependency to your `build.zig.zon` file.

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.6.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

### Method 4: Local Source Checkout

Clone the repository locally.

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

To use a local checkout from another project, add a path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .httpx = .{
        .path = "../httpx.zig",
    },
},
```

### Wire into `build.zig`

After adding the dependency, import the module in your `build.zig`:

```zig
const httpx_dep = b.dependency("httpx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
```

## Quick Start

### One-Liner Requests

```zig
const httpx = @import("httpx");

// GET — simplest possible request
var resp = try httpx.get("https://httpbun.com/get", .{});
defer resp.deinit();

// POST JSON
var post = try httpx.post("https://httpbun.com/post", .{ .json = "{\"name\":\"Alice\"}" });
defer post.deinit();

// Other methods
var del = try httpx.delete("https://httpbun.com/delete", .{});
defer del.deinit();
var patch = try httpx.patch("https://httpbun.com/patch", .{ .json = "{\"x\":1}" });
defer patch.deinit();
var head = try httpx.head("https://httpbun.com/get", .{});
defer head.deinit();
```

### Client Usage

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = httpx.createClientWithConfig(allocator, .{
        .base_url = "https://httpbun.com",
    });
    defer client.deinit();

    // GET
    var response = try client.get("/get", .{});
    defer response.deinit();

    // POST JSON
    var post = try client.post("/post", .{ .json = "{\"name\":\"John\"}" });
    defer post.deinit();

    // Parse JSON response
    const User = struct { id: u32, name: []const u8 };
    if (response.json(User, .{})) |parsed| {
        defer parsed.deinit();
        std.debug.print("User: {s}\n", .{parsed.value.name});
    } else |_| {}
}
```

### Simplified API Aliases

```zig
// All HTTP methods as top-level functions
var r1 = try httpx.get("https://httpbun.com/get", .{});
var r2 = try httpx.post("https://httpbun.com/post", .{ .json = "{}" });
var r3 = try httpx.put("https://httpbun.com/put", .{});
var r4 = try httpx.del("https://httpbun.com/delete", .{});
var r5 = try httpx.patch("https://httpbun.com/patch", .{});
var r6 = try httpx.head("https://httpbun.com/head", .{});
var r7 = try httpx.opts("https://httpbun.com/options", .{});
var r8 = try httpx.trace("https://httpbun.com/trace", .{});

// fetch = alias for get
var r9 = try httpx.fetch("https://httpbun.com/get", .{});

// send with explicit method
var r10 = try httpx.send(.GET, "https://httpbun.com/get", .{});

// With explicit allocator
var r11 = try httpx.sendWithAllocator(allocator, .POST, "https://httpbun.com/post", .{ .json = "{}" });

// JSON helpers
const User = struct { id: u32, name: []const u8 };
const result = try httpx.getJson(User, "https://api.example.com/user/1", .{});
defer result.response.deinit();
defer result.value.deinit();

const created = try httpx.postJsonAndParse(User, "https://api.example.com/users", .{}, .{ .name = "Alice" }, .{});
defer created.response.deinit();
defer created.value.deinit();
```

### Concurrency

```zig
// Parallel requests — run all, first, or fastest
var client = httpx.createClient();
defer client.deinit();

const specs = [_]httpx.RequestSpec{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};

// all: wait for every request
var results = try httpx.all(allocator, &client, &specs, .{});
defer { for (results) |*r| r.deinit(); allocator.free(results); }

// first: return first 2xx response
var ok = try httpx.first(allocator, &client, &specs, .{});
if (ok) |*resp| resp.deinit();

// fastest: return first to complete (success or error)
var fast = try httpx.fastest(allocator, &client, &specs, .{});
fast.deinit();
```

### Server

```zig
const std = @import("std");
const httpx = @import("httpx");

fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .message = "Hello!" });
}

fn page(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html("<h1>Welcome</h1>");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // One-shot server — one line
    try httpx.serve("/hello", hello);
    // OR full control:
    var server = httpx.createServer();
    defer server.deinit();
    try server.use(httpx.logger());
    try server.use(httpx.cors(.{}));
    try server.use(httpx.helmet());
    try server.use(httpx.rateLimit(.{ .max_requests = 100 }));
    try server.get("/hello", hello);
    try server.get("/page", page);
    try server.listen();
}
```

### Middleware

```zig
try server.use(httpx.cors(.{ .allow_origins = &.{"*"} }));
try server.use(httpx.logger());
try server.use(httpx.helmet());
try server.use(httpx.rateLimit(.{ .max_requests = 100 }));
try server.use(httpx.basicAuth("admin", myValidator));
try server.use(httpx.csrf(.{}));
try server.use(httpx.bodyParser(1024 * 1024));
try server.use(httpx.requestTimeout(30_000));
try server.use(httpx.requestId());
```

### Network Helpers

```zig
const addr = try httpx.resolveAddress("example.com", 443);
const parsed = try httpx.parseHostAndPort("localhost:8080", 80);
const resolved = try httpx.parseAndResolveAddress("127.0.0.1:9000", 80);
const is_ip = httpx.isIpAddress("::1"); // true
```
 
## Examples

The `examples/` directory contains **57 comprehensive, runnable examples** demonstrating all features of `httpx.zig`:

**Client:**
- [`simple_get`](examples/simple_get.zig) - Basic GET requests
- [`simple_get_deserialize`](examples/simple_get_deserialize.zig) - GET with JSON deserialization
- [`json_api_example`](examples/json_api_example.zig) - JSON API: getJson, postJsonAndParse, Response.json, server ctx.jsonBody + ctx.json
- [`post_json`](examples/post_json.zig) - POST with JSON body
- [`custom_headers`](examples/custom_headers.zig) - Custom header management
- [`http_auth_helpers`](examples/http_auth_helpers.zig) - Bearer and Basic auth helpers
- [`connection_pool`](examples/connection_pool.zig) - Connection pooling and stats
- [`proxy_example`](examples/proxy_example.zig) - HTTP forward proxy and SOCKS5h
- [`socks5_proxy`](examples/socks5_proxy.zig) - SOCKS5 proxy tunneling
- [`interceptors`](examples/interceptors.zig) - Request/response interceptors
- [`cookies_demo`](examples/cookies_demo.zig) - Cookie jar management
- [`concurrent_requests`](examples/concurrent_requests.zig) - Parallel request patterns
- [`batch_concurrent`](examples/batch_concurrent.zig) - Batch concurrent requests
- [`simplified_api_aliases`](examples/simplified_api_aliases.zig) - Top-level API aliases
- [`http_methods`](examples/http_methods.zig) - HTTP method helpers
- [`https_client`](examples/https_client.zig) - HTTPS client with TLS
- [`redirect_example`](examples/redirect_example.zig) - Redirect handling
- [`retry_example`](examples/retry_example.zig) - Retry with backoff
- [`dns_example`](examples/dns_example.zig) - DNS resolution
- [`compression_example`](examples/compression_example.zig) - gzip/deflate/brotli/zstd

**Server:**
- [`simple_server`](examples/simple_server.zig) - Minimal HTTP server
- [`tls_server`](examples/tls_server.zig) - TLS-enabled server
- [`cloud_https_server`](examples/cloud_https_server.zig) - Cloud HTTPS server
- [`router_example`](examples/router_example.zig) - Pattern-based routing
- [`middleware_example`](examples/middleware_example.zig) - Middleware stack
- [`static_files`](examples/static_files.zig) - Static file serving
- [`multi_page_website`](examples/multi_page_website.zig) - Multi-page web app
- [`streaming`](examples/streaming.zig) - Chunked transfer and SSE
- [`sse_example`](examples/sse_example.zig) - Server-Sent Events
- [`health_check_example`](examples/health_check_example.zig) - Liveness/readiness probes
- [`readiness_probe_example`](examples/readiness_probe_example.zig) - Readiness probe and health check middleware
- [`pre_route_example`](examples/pre_route_example.zig) - Pre-route hooks and global handler
- [`request_response_customization`](examples/request_response_customization.zig) - Request/response customization
- [`async_server_example`](examples/async_server_example.zig) - Thread pool concurrency
- [`logging_callback`](examples/logging_callback.zig) - Custom logging, silent mode, and log_level filtering
- [`reverse_proxy_middleware`](examples/reverse_proxy_middleware.zig) - Reverse proxy middleware

**Protocol:**
- [`http2_example`](examples/http2_example.zig) - HTTP/2 protocol primitives
- [`http2_client_runtime`](examples/http2_client_runtime.zig) - HTTP/2 client runtime
- [`http2_server_runtime`](examples/http2_server_runtime.zig) - HTTP/2 server runtime
- [`http2_advanced`](examples/http2_advanced.zig) - HTTP/2 SETTINGS enforcement, GOAWAY, HPACK security, trailers
- [`http3_example`](examples/http3_example.zig) - HTTP/3 protocol primitives
- [`http3_client_runtime`](examples/http3_client_runtime.zig) - HTTP/3 client runtime
- [`http3_server_runtime`](examples/http3_server_runtime.zig) - HTTP/3 server runtime
- [`http3_advanced`](examples/http3_advanced.zig) - QPACK stream instructions, QUIC cancellation, transport parameters

**TLS:**
- [`tls_https_get`](examples/tls_https_get.zig) - Simple HTTPS GET via local TLS server (HTTP/1.1 + HTTP/2 + HTTP/3)
- [`tls_config_options`](examples/tls_config_options.zig) - TLS configuration options and ALPN negotiation
- [`tls_handshake_details`](examples/tls_handshake_details.zig) - TLS handshake info and cipher suites
- [`tls_custom_ca`](examples/tls_custom_ca.zig) - Custom CA certificate verification with self-signed certs
- [`tls_mtls`](examples/tls_mtls.zig) - Mutual TLS (mTLS) client certificate authentication

**Advanced Capabilities:**
- [`websocket_example`](examples/websocket_example.zig) - RFC 6455 WebSocket client
- [`websocket_server`](examples/websocket_server.zig) - WebSocket server
- [`multipart_example`](examples/multipart_example.zig) - RFC 2046 multipart form data
- [`session_example`](examples/session_example.zig) - TTL-based session store
- [`metrics_example`](examples/metrics_example.zig) - Observability metrics
- [`unix_socket_example`](examples/unix_socket_example.zig) - AF_UNIX domain sockets
- [`tcp_local`](examples/tcp_local.zig) - TCP socket helpers
- [`udp_local`](examples/udp_local.zig) - UDP socket helpers

To run any example:
```bash
zig build run-all-<example_name>
# e.g., zig build run-all-simple_get
# e.g., zig build run-all-websocket_example
```

## Validation Matrix

Validate host functionality and cross-target compatibility with these commands:

```bash
# Host runtime validation
zig build test
zig build run-all-examples  # Runs sequentially to prevent parallel compiler OOM / PC crashes

# Cross-target library compile validation
zig build build-all-targets
```

To validate Linux runtime behavior (not just compilation), run Linux-target artifacts from a Linux shell (or WSL):

```bash
# Build Linux test/example artifacts
zig build test -Dtarget=x86_64-linux
zig build example-tcp_local -Dtarget=x86_64-linux

# Run on Linux/WSL
./zig-out/bin/test
./zig-out/bin/tcp_local
```

If a remote endpoint appears to stall, set a per-request timeout and print errors explicitly:

```zig
var response = client.get(url, .{ .timeout_ms = 10_000 }) catch |err| {
    std.debug.print("request failed: {s}\n", .{@errorName(err)});
    return;
};
defer response.deinit();
```

For explicit cross-target test and example compilation, pass `-Dtarget=...`:

```bash
# Example: compile tests for 32-bit Windows
zig build test -Dtarget=x86-windows

# Example: compile an example for macOS ARM64
zig build example-tcp_local -Dtarget=aarch64-macos
```

> Note: this project exposes `build-all-targets` as a build step. Use `zig build build-all-targets`.
 
## Performance
 
Run benchmarks:
 
```bash
zig build bench
```
> [!NOTE]
> Benchmark results will vary based on hardware and network conditions.
> The benchmark suite reports multiple rounds with min/avg/max and throughput to improve result quality.

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
 
## Contributing
 
Contributions are welcome! Please:
 
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request
 
## License
 
MIT License - see [LICENSE](LICENSE) for details.
