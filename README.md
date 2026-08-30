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
> If you build with httpx.zig, make sure to give it a star.

> [!NOTE]
> **Project maturity:** This project is production-ready and actively maintained. It provides a comprehensive HTTP client and server implementation with modern protocol, networking, security, and performance features.
>
> **Custom HTTP/2, HTTP/3, TLS, Streaming, and Parsing implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, TLS/ALPN, OpenAPI documentation UI, full HTML/XML DOM parsing, or built-in progress download engines.
> httpx.zig implements these subsystems **entirely from scratch and natively in Zig**, including:
> - **TLS 1.2 and 1.3** with full handshake support (RFC 5246 / RFC 8446) — key exchange: X25519; AEAD cipher suites: ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM; ALPN negotiation (RFC 7301) for automatic HTTP/2 and HTTP/3 protocol selection with HTTP/1.1 fallback; X.509 certificate parsing and verification; custom record-layer encryption/decryption
> - **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
> - **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 7540)
> - **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
> - **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, version negotiation, and transport parameters
> - **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
> - **Streaming Downloader & File Manager** with zero-config `loaders.zig` progress bars, dynamic speed & ETA estimation, range-based resumption, atomic updates, and cryptographic verification (SHA-256, SHA-384, SHA-512, MD5, SHA-1)
> - **Unified DOM Engine & Web Resource Inspector** for HTML5, XML, RSS/Atom/JSON feeds, robots.txt, sitemaps, and CSS selector queries with zero manual per-element memory freeing
> - **Self-Hosted Interactive Documentation** supporting Swagger UI, ReDoc, Scalar, and GraphiQL with embedded offline assets


**Related Zig projects:**

- For **Env.zig** (.env parsing), check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **ZON file format** support, check out **[zon.zig](https://github.com/muhammad-fiaz/zon.zig)**.
- For **Spinners/loading/progress bar** support, check out **[loaders.zig](https://github.com/muhammad-fiaz/loaders.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.
- For **Args parsing** support, check out **[args.zig](https://github.com/muhammad-fiaz/args.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **Web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **CUDA** support, check out **[cuda.zig](https://github.com/muhammad-fiaz/cuda.zig)**.
- For **Simplified build.zig config** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.
- For **SQLite (zig-native implementation)** support, check out **[sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig)**.
- For **File downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **Numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **Logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **Data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
- For **UUID** support, check out **[uuid.zig](https://github.com/muhammad-fiaz/uuid.zig)**.
- For **Key-Value database** support, check out **[zkv.zig](https://github.com/muhammad-fiaz/zkv.zig)**.
- For **Terminal color & text styles** support, check out **[hint.zig](https://github.com/muhammad-fiaz/hint.zig)**.
- For **Brotli compression** support, check out **[brotli.zig](https://github.com/muhammad-fiaz/brotli.zig)**.
- For **Zstd compression** support, check out **[zstd.zig](https://github.com/muhammad-fiaz/zstd.zig)**.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Protocol Support** | Full runtime support for **HTTP/1.0**, **HTTP/1.1**, **HTTP/2**, and **HTTP/3** in high-level client/server APIs, plus low-level protocol primitives. |
| **Header Compression** | HPACK (RFC 7541) for HTTP/2; QPACK (RFC 9204) for HTTP/3 with static and dynamic table management. |
| **HTTP/2 & HTTP/3 ALPN** | Automatic protocol negotiation during TLS handshake with graceful HTTP/1.1 fallback. |
| **Stream Multiplexing** | HTTP/2 stream state machine with flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, and trailers. |
| **Connection Pooling** | Automatic reuse of TCP & HTTP/2 connections with keep-alive, health checking, and parking caps. |
| **Unified DOM & Web Parsing** | Native parser for HTML5, XML, RSS/Atom/JSON feeds, robots.txt, and sitemaps with zero-leak arena architecture. |
| **Streaming Downloader** | Resumable chunked file downloader powered by `loaders.zig` progress bars, ETA calculation, and hash verification. |
| **Pattern-based Routing** | Intuitive server routing with dynamic parameters (`/users/:id`), wildcards (`/*path`), and route groups. |
| **Middleware Stack** | Built-in middleware for CORS, Compression (gzip/deflate/brotli/zstd), Timeout, Rate Limiting, Logging, Auth, Helmet, CSRF, Reverse Proxy, Body Parsing, Request ID, and Health probes. |
| **TLS/SSL** | Full TLS 1.2 and 1.3 with ALPN (RFC 7301), X25519 key exchange, AEAD ciphers, X.509 cert parsing, and mTLS support. |
| **Static Files & SPA** | High-performance static file serving with ETag, cache control, conditional GET, MIME detection, and SPA HTML5 fallback. |
| **Interactive API Docs** | Auto-generated OpenAPI 3.1 specifications with embedded Swagger UI, ReDoc, Scalar, and GraphiQL interfaces. |
| **Streaming & Realtime** | Chunked transfer responses with optional trailers, Server-Sent Events (SSE), and WebSocket frame support. |
| **HTTP Caching** | `CacheControl` header parsing, `HttpCache` (LRU in-memory with TTL), and `ConditionalGet` (ETag/If-None-Match). |
| **DNS Resolution** | Resolution with caching, concurrent resolver coalescing, and SSRF policy checks. |
| **Cookie APIs** | First-class request/response cookie jar and header helpers for both client and server contexts. |
| **Security & Hardening** | Security headers (Helmet), CSRF protection, SSRF protection in reverse proxy, and CRLF injection defenses. |
| **Multipart Form Data** | RFC 2046 streaming multipart body builder and parser for text fields and large file uploads. |
| **FTP & FTPS** | Full FTP client and server with PASV/EPSV, directory listing, streaming uploads/downloads, and resumption. |
| **Concurrency & Workers** | Thread-safe bounded `WorkerPool`, parallel requests (`getAll`, `requestAll`), and async task execution. |
| **Proxy Support** | Client-side HTTP forward proxy, SOCKS5h tunneling, and server-side reverse proxy middleware. |
| **Structured Logging** | Zero-allocation level-filtered structured logger supporting custom sinks and terminal formatting. |
| **Cross-Platform Sockets** | Robust non-blocking Windows socket handling with `WSAEWOULDBLOCK` retry, plus `MSG_NOSIGNAL` on POSIX. |

</details>


---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.16.0** (recommended) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

> [!IMPORTANT]
> **Zig 0.16.0 is required.** This project currently targets Zig 0.16.0 (stable). Zig 0.17.0 is in development (dev branch, not yet a stable release) and introduces several minor breaking changes from 0.16.0. Migration to 0.17.0 will happen once it is officially released as a stable version. Please use Zig 0.16.0 for all builds.

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

**Latest Stable Release (v0.1.8)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz
```

**Previous Stable Release (v0.1.7)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.7.tar.gz
```

> [!WARNING]
> Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.16.0+** with **httpx.zig v0.1.8**.

### Method 2: Zig Fetch (Dev Branch)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.8.tar.gz",
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

## Quick Start

### Global Functions (Zero-Config, No Allocator Required)

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    // 1. Simple GET with options struct
    var resp = try httpx.get(.{ .url = "https://httpbun.com/get" });
    defer resp.deinit();
    std.debug.print("GET Status: {d}, Body: {s}\n", .{ resp.status, resp.body });

    // 2. POST with JSON body
    var post = try httpx.post(.{
        .url = "https://httpbun.com/post",
        .json = "{\"name\":\"Alice\"}",
    });
    defer post.deinit();

    // 3. DELETE request
    var del = try httpx.delete(.{ .url = "https://httpbun.com/delete" });
    defer del.deinit();

    // 4. PATCH with struct or JSON string
    var patch = try httpx.patch(.{
        .url = "https://httpbun.com/patch",
        .json = "{\"x\":1}",
    });
    defer patch.deinit();

    // 5. HEAD request
    var head = try httpx.head(.{ .url = "https://httpbun.com/get" });
    defer head.deinit();
}
```


### Client Usage (Full Config)

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client with full config (allocator owned at boundary)
    var client = try httpx.Client.init(allocator, .{
        .timeout_ms = 10_000,
        .max_redirects = 5,
        .max_retries = 3,
        .retry_delay_ms = 500,
        .retry_status_codes = &.{ 502, 503, 504 },
        .dns_cache = .{ .enabled = true, .ttl_ms = 60_000 },
    });
    defer client.deinit();

    // GET request
    var response = try client.get(.{ .url = "https://httpbun.com/get" });
    defer response.deinit();

    // POST with JSON
    var post = try client.post(.{
        .url = "https://httpbun.com/post",
        .json = "{\"name\":\"John\"}",
    });
    defer post.deinit();


    // HTTPS with TLS options
    var tls_resp = try client.get(.{
        .url = "https://httpbun.com/get",
        .tls = .{ .verify = .none }, // dev only
    });
    defer tls_resp.deinit();

    // Graceful close (purge connection pool)
    client.close();

    // Full reset (close + clear DNS cache)
    client.reset();
}
```

### Batch Requests

```zig
// Parallel requests - getAll (arrays and slices accepted directly)
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
var results = try httpx.getAll(urls);
defer { for (results) |*r| r.deinit(); }

// Parallel requests - requestAll
const reqs = [_]httpx.RequestOptions{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
var batch = try httpx.requestAll(reqs);
defer { for (batch) |*r| r.deinit(); }
```


### File Downloads & Progress Reporting

`httpx.zig` includes a production-grade streaming download, resume, and file verification subsystem powered by `loaders.zig` for terminal progress bars:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";

    // 1. Zero-config download with automatic filename & loaders.zig progress bar
    const res = try client.download(sample_url, "downloads/", .{
        .progress = .auto,
        .existing = .overwrite,
        .create_dirs = true,
    });
    std.debug.print("Downloaded: {s} ({d} bytes)\n", .{ res.destination, res.downloaded_bytes });

    // 2. Download with in-flight cryptographic SHA-256 verification
    const verified_res = try client.download(sample_url, "downloads/sample.pdf", .{
        .verify = .{
            .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .min_size = 100,
            .max_size = 50 * 1024 * 1024,
        },
        .atomic = true, // downloads to temp file first, renames on valid hash
    });

    // 3. Inspect remote file metadata without downloading (size, filename, ranges)
    const file_info = try client.lookupFileInfo(sample_url, .{});
    var size_str_buf: [32]u8 = undefined;
    std.debug.print("Remote file: {s}, size: {s}\n", .{ file_info.fileName(), file_info.formatSize(&size_str_buf) });

    // 4. Resume partial download via HTTP Range: bytes=X- (clean non-reserved keyword name)
    const resumed_res = try client.download(sample_url, "downloads/sample.pdf", .{
        .existing = .resume_download, // or .continue_partial
        .max_retries = 3,
    });

    // 5. Safe file updater with rollback backup
    const update_res = try client.updateFile(sample_url, "bin/app.bin", .{
        .backup_existing = true,
        .backup_suffix = ".bak",
    });

    // 6. Native FTP Download with progress
    const ftp_res = try httpx.ftpDownload(allocator, .{
        .host = "ftp.example.com",
        .remote_path = "/pub/archive.tar.gz",
        .destination_path = "downloads/",
        .progress = .auto,
    });
}
```

### Parsing & Inspection (DOM Engine)

`httpx.zig` includes a comprehensive parsing and web resource inspection engine written natively in Zig:


```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    // 1. Initialize unified parser with reusable allocator & configuration
    var p = httpx.parsing.init(allocator, .{});

    // 2. Parse HTML directly
    var doc = try p.parseHtml("<html><head><title>My Page</title></head><body><h1 class='title'>Hello</h1><a href='/link'>Click</a></body></html>");
    defer doc.deinit();

    // Fluent zero-allocator navigation
    const title = try doc.title();
    const links = try doc.links();
    var h1_nodes = try doc.select("h1.title");
    defer h1_nodes.deinit();

    // 3. Parse RSS / Atom / JSON Feed
    var feed = try p.parseFeed(xml_feed_str, null);
    defer feed.deinit();

    // 4. Parse robots.txt
    var robots = try p.parseRobots("User-agent: *\nDisallow: /admin/\n");
    defer robots.deinit();
    const allowed = robots.isAllowed("MyBot", "/public");

    // 5. Parse Sitemap XML
    var sitemap = try p.parseSitemap(sitemap_xml_str);
    defer sitemap.deinit();
}
```



### Server

```zig
const std = @import("std");
const httpx = @import("httpx");

fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .message = "Hello!" });
}

fn page(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html("<h1>Welcome</h1>");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_strategy = .incremental, // auto-increments port (8081, 8082, ...) if 8080 is busy
    });
    defer server.deinit();

    try server.get("/hello", hello);
    try server.get("/page", page);
    server.run();
}
```

### TLS Server

```zig
const std = @import("std");
const httpx = @import("httpx");

fn handler(req: httpx.TlsRequest, ctx: ?*anyopaque) httpx.TlsResponse {
    _ = ctx;
    return .{ .body = "Hello over TLS!" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tls_listener = try httpx.TlsListener.init(allocator, .{
        .port = 8443,
        .default_identity = .{
            .cert_chain_pem = @embedFile("cert.pem"),
            .private_key_pem = @embedFile("key.pem"),
        },
    });
    defer tls_listener.deinit();

    // Blocking accept loop — use requestShutdown() to break out
    try tls_listener.run(handler, null);
}
```

## Server Lifecycle

```zig
// Blocking — runs until requestShutdown() or stop() is called
server.run();

// Non-blocking — spawns a thread, returns handle for join()
const thread = try server.start();

// Pause accepting new connections (existing connections continue)
server.pause();

// Resume accepting new connections
server.resumeAccepting();

// Graceful shutdown — finishes in-flight requests, then stops
server.requestShutdown();

// Immediate shutdown — closes listener and all connections now
server.stop();
```

## TLS Listener Lifecycle

```zig
// Blocking accept loop
try tls_listener.run(handler, null);

// Graceful shutdown
tls_listener.requestShutdown();

// Close the listener socket immediately
tls_listener.close();
```

## Client Lifecycle

```zig
// Graceful close — purges the connection pool
client.close();

// Full reset — close + clear DNS cache
client.reset();
```

## Client Retry

Configure automatic retries for failed or retryable requests:

```zig
var client = try httpx.Client.init(allocator, .{
    .max_retries = 3,                // retry up to 3 times (4 total attempts)
    .retry_delay_ms = 500,           // base delay between retries
    .retry_status_codes = &.{ 502, 503, 504 }, // status codes that trigger retry
});
```

The delay between retries increases linearly: `retry_delay_ms * (attempt + 1)`.

## DNS Resolution

```zig
var resolver = httpx.resolve.Resolver.init(allocator);
const addrs = try resolver.lookup("example.com", 443);
defer allocator.free(addrs);
```

## Context Methods & Response Types

```zig
fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    // 1. Query parameters & Cookies
    const page = ctx.queryParam("page") orelse "1";
    const token = ctx.cookie("session");

    // 2. Remote address
    const addr = ctx.remoteAddress() orelse "unknown";

    // 3. Rich Responses
    if (std.mem.eql(u8, page, "html")) return ctx.html("<h1>Welcome</h1>");
    if (std.mem.eql(u8, page, "text")) return ctx.text("Plain text response");
    if (std.mem.eql(u8, page, "xml")) return ctx.xml("<data>sample</data>");
    if (std.mem.eql(u8, page, "rss")) return ctx.rss("<rss version=\"2.0\"><channel></channel></rss>");
    if (std.mem.eql(u8, page, "atom")) return ctx.atom("<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>");
    if (std.mem.eql(u8, page, "robots")) return ctx.robots("User-agent: *\nAllow: /");
    if (std.mem.eql(u8, page, "sitemap")) return ctx.sitemap("<urlset></urlset>");
    if (std.mem.eql(u8, page, "binary")) return ctx.binary(&[_]u8{ 0x01, 0x02, 0x03 }, "application/octet-stream");

    return ctx.renderJson(.{ .page = page, .addr = addr, .token = token });
}
```

## Examples

The `examples/` directory contains runnable examples demonstrating all features of `httpx.zig`:

**Client:**
- [`simple_get`](examples/simple_get.zig) - Basic GET requests
- [`post_json`](examples/post_json.zig) - POST with JSON body
- [`custom_headers`](examples/custom_headers.zig) - Custom header management
- [`connection_pool`](examples/connection_pool.zig) - Connection pooling and stats
- [`redirect`](examples/redirect.zig) - Redirect handling
- [`http10_client`](examples/http10_client.zig) - HTTP/1.0 client
- [`tls_get`](examples/tls_get.zig) - HTTPS client with TLS
- [`https_client`](examples/https_client.zig) - HTTPS client with TLS
- [`tls12_client`](examples/tls12_client.zig) - TLS 1.2 with self-signed cert
- [`tls13_client`](examples/tls13_client.zig) - TLS 1.3 with self-signed cert
- [`tls_mtls`](examples/tls_mtls.zig) - Mutual TLS (mTLS)
- [`resolve`](examples/resolve.zig) - DNS resolution
- [`concurrent_demo`](examples/concurrent_demo.zig) - Parallel request patterns
- [`proxy_demo`](examples/proxy_demo.zig) - HTTP forward proxy
- [`dns_demo`](examples/dns_demo.zig) - DNS resolution and IP checks
- [`dns_cache`](examples/dns_cache.zig) - DNS caching
- [`compression_demo`](examples/compression_demo.zig) - gzip/deflate/brotli compression
- [`retry_demo`](examples/retry_demo.zig) - Retry with exponential backoff

**Server:**
- [`simple_server`](examples/simple_server.zig) - Minimal HTTP server
- [`custom_responses`](examples/custom_responses.zig) - Rich response generation (HTML, JSON, XML, RSS, Atom, robots.txt, sitemap.xml, binary)
- [`static_files`](examples/static_files.zig) - Static file serving with ETag
- [`health_check`](examples/health_check.zig) - Liveness/readiness probes
- [`streaming`](examples/streaming.zig) - Chunked transfer and SSE
- [`auth_and_errors`](examples/auth_and_errors.zig) - Authentication and error handling
- [`live_static_watcher`](examples/live_static_watcher.zig) - Live file watcher and auto-reload
- [`docs_server`](examples/docs_server.zig) - Swagger UI, ReDoc, Scalar, GraphiQL
- [`graphql_server`](examples/graphql_server.zig) - GraphQL server
- [`spa_fallback`](examples/spa_fallback.zig) - SPA with HTML/JS/CSS and client-side routing
- [`websocket_server`](examples/websocket_server.zig) - WebSocket server
- [`sse_server`](examples/sse_server.zig) - Server-Sent Events
- [`session_server`](examples/session_server.zig) - TTL-based session management
- [`metrics_server`](examples/metrics_server.zig) - Prometheus metrics
- [`interceptor_example`](examples/interceptor_example.zig) - Request/response interceptors
- [`cookie_server`](examples/cookie_server.zig) - Cookie management
- [`cors_server`](examples/cors_server.zig) - CORS configuration
- [`helmet_server`](examples/helmet_server.zig) - Security headers (Helmet)
- [`rate_limit_server`](examples/rate_limit_server.zig) - Rate limiting
- [`body_parser_server`](examples/body_parser_server.zig) - Request body parsing
- [`custom_server`](examples/custom_server.zig) - Request ID and body parsing
- [`tls_server`](examples/tls_server.zig) - HTTPS/TLS server with self-signed cert
- [`ftp_server`](examples/ftp_server.zig) - FTP-like server

**Download & File Inspection:**
- [`download`](examples/download.zig) - Download with built-in progress bar and destination inference
- [`download_batch`](examples/download_batch.zig) - Concurrent worker pool batch downloads
- [`download_resume`](examples/download_resume.zig) - Range-based resumption
- [`download_verify`](examples/download_verify.zig) - Cryptographic verification (SHA-256, SHA-384, SHA-512, MD5, SHA-1)
- [`download_checksum_file`](examples/download_checksum_file.zig) - Remote checksum file lookup and verification
- [`download_existing`](examples/download_existing.zig) - Existing file policies (fail, overwrite, skip, resume, replace_if_changed)
- [`download_update`](examples/download_update.zig) - Atomic self-updates with rollback safety
- [`download_info`](examples/download_info.zig) - Metadata HEAD inspection without full body download
- [`download_custom_progress`](examples/download_custom_progress.zig) - Custom progress tracking and observers
- [`ftp_download`](examples/ftp_download.zig) - Direct FTP file download

**Parsing & Inspection (Native DOM Engine):**
- [`parse_html`](examples/parse_html.zig) - HTML DOM, CSS Selectors, RSS feeds, robots.txt, and sitemaps


**Protocol:**
- [`http2_client`](examples/http2_client.zig) - HTTP/2 client
- [`http2_multiplex`](examples/http2_multiplex.zig) - HTTP/2 stream multiplexing
- [`http3_client`](examples/http3_client.zig) - HTTP/3 client
- [`http3_quic`](examples/http3_quic.zig) - HTTP/3 over QUIC

**Advanced:**
- [`multipart`](examples/multipart.zig) - Multipart form data
- [`openapi`](examples/openapi.zig) - OpenAPI spec generation
- [`ftp_client`](examples/ftp_client.zig) - FTP client


**Static Assets (for SPA example):**
- [`static/index.html`](examples/static/index.html) - Main HTML page
- [`static/about.html`](examples/static/about.html) - About page
- [`static/contact.html`](examples/static/contact.html) - Contact page with form
- [`static/styles.css`](examples/static/styles.css) - CSS styles
- [`static/app.js`](examples/static/app.js) - Client-side JavaScript

To run any example:
```bash
zig build run-<example_name>
# e.g., zig build run-simple_get
# e.g., zig build run-spa_fallback
```

## API Reference

### Public Exports

```zig
// Client API
httpx.Client           // Client struct (init takes allocator)
httpx.ClientConfig     // Client configuration type
httpx.ClientResponse   // Response type
httpx.Header           // Header type
httpx.Headers          // Headers collection
httpx.CookieJar        // Cookie jar
httpx.ConnectionPool   // Connection pool
httpx.PoolConfig       // Pool configuration
httpx.RequestOptions   // Per-request options

// Client lifecycle
client.close()         // Purge connection pool
client.reset()         // Close + clear DNS cache

// Client retry config (in Config)
.max_retries           // Number of retry attempts (0 = disabled)
.retry_delay_ms        // Delay between retries in ms (default 1000)
.retry_status_codes    // Status codes that trigger retry (default 502, 503, 504)

// Global functions (no allocator needed)
httpx.get(.{ .url = "..." })
httpx.post(.{ .url = "...", .json = "..." })
httpx.put(.{ .url = "...", .json = "..." })
httpx.patch(.{ .url = "...", .json = "..." })
httpx.delete(.{ .url = "..." })
httpx.head(.{ .url = "..." })
httpx.options(.{ .url = "..." })
httpx.trace(.{ .url = "..." })
httpx.connect(.{ .url = "..." })
httpx.fetch(.{ .url = "..." })
httpx.request(.{ .method = .GET, .url = "..." })
httpx.send(.{ .method = .GET, .url = "..." })
httpx.getAll(&urls)
httpx.requestAll(&reqs)

// Server API
httpx.Server           // Server struct (init takes allocator)
httpx.ServerConfig     // Server configuration type
httpx.Router           // Router type
httpx.Context          // Request context type (has queryParam, cookie, remoteAddress methods)
httpx.Response         // Response type

// Server lifecycle
server.run()           // Blocking accept loop
server.start()         // Non-blocking, returns std.Thread
server.stop()          // Immediate shutdown
server.requestShutdown() // Graceful shutdown
server.pause()         // Pause accepting new connections
server.resumeAccepting() // Resume accepting new connections

// TLS API
httpx.TlsListener     // TLS listener (init takes allocator)
httpx.TlsListenerConfig // TLS listener configuration
httpx.TlsConfig       // TLS server config
httpx.TlsClientConfig // TLS client config

// TLS lifecycle
tls_listener.run(handler, ctx)      // Blocking accept loop
tls_listener.requestShutdown()      // Graceful shutdown
tls_listener.close()                // Close listener socket

// Protocol APIs
httpx.http1            // HTTP/1.x parser, writer, semantics
httpx.http2            // HTTP/2 frame, hpack, stream, connection, transport
httpx.http3            // HTTP/3 frame, qpack, connection
httpx.quic             // QUIC varint, packet, crypto, frames, connection

// Network APIs
httpx.tcp              // TCP socket, listener, IoContext
httpx.udp              // UDP socket
httpx.dns              // DNS resolution
httpx.resolve.Resolver // DNS resolver (init(alloc), lookup(host, port))
httpx.socks5           // SOCKS5 proxy
httpx.proxy            // HTTP proxy

// FTP
httpx.ftp.Client       // FTP client
httpx.ftp.Server       // FTP server
httpx.ftp.Options      // FTP client options
httpx.ftp.Callbacks    // FTP server callbacks

// Web APIs
httpx.static.files     // Static file serving
httpx.static.spa       // SPA serving
httpx.static.Watcher   // File watcher
httpx.health           // Health check endpoints
httpx.metrics          // Metrics registry
httpx.mime             // MIME type detection
httpx.openapi          // OpenAPI spec
httpx.docs             // Documentation UI
httpx.graphql          // GraphQL support
httpx.auth             // Auth helpers (basic, bearer)
httpx.multipart        // Multipart encoder/parser
httpx.compression      // Compression codecs
httpx.router.Router    // Router type
httpx.router.Context   // Request context
httpx.router.Response  // Response type
httpx.router.pattern   // Route pattern parsing
httpx.router.metadata  // Route metadata
httpx.sse.Writer       // SSE writer
httpx.sse.Parser       // SSE parser
httpx.ws.Handshake     // WebSocket handshake
httpx.ws.Frame         // WebSocket frame

// Utility types
httpx.RateLimiter      // Rate limiter
httpx.WorkerPool       // Worker pool
httpx.Queue            // Bounded queue
httpx.Logger           // Logger
httpx.LogLevel         // Log level

// Common types
httpx.Address          // Network address
httpx.Uri              // URI type
httpx.Method           // HTTP method
httpx.Status           // HTTP status

// Version
httpx.name             // Library name
httpx.version          // Library version
```

## Validation Matrix

```bash
# Host runtime validation
zig build test
zig build run-all-examples   # Runs sequentially to prevent parallel compiler OOM

# Cross-target library compile validation
zig build build-all-targets
```

To validate Linux runtime behavior (not just compilation):

```bash
zig build test -Dtarget=x86_64-linux
zig build run-simple_get -Dtarget=x86_64-linux
```

For explicit cross-target compilation:

```bash
# Compile tests for 32-bit Windows
zig build test -Dtarget=x86-windows

# Compile an example for macOS ARM64
zig build run-simple_get -Dtarget=aarch64-macos
```

## Performance

Run benchmarks:

```bash
zig build bench
```

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

## Project Structure

```
httpx.zig/
├── src/
│   ├── httpx.zig                    # Public API entry point & re-exports
│   ├── client/                      # HTTP client
│   │   ├── client.zig               # Client struct, connection pooling, retry
│   │   ├── request.zig              # Raw request API, TLS options, auto-TLS
│   │   ├── cookies.zig              # Client cookie jar
│   │   └── download.zig             # File download, resume, verify, batch
│   ├── server/
│   │   └── lifecycle.zig            # Server struct, Config, run/stop/start, Ctrl+C
│   ├── web/
│   │   ├── router/                  # Router, Context, Response, pattern matching
│   │   ├── middleware/              # CORS, Helmet, rate-limit, auth, CSRF, proxy
│   │   ├── static_files/            # Static file serving, ETag, MIME detection
│   │   ├── spa/                     # SPA HTML5 fallback serving
│   │   ├── openapi/                 # OpenAPI 3.1 spec generation
│   │   ├── docs/                    # Swagger UI, ReDoc, Scalar, GraphiQL
│   │   ├── graphql/                 # GraphQL schema, resolvers, mount
│   │   ├── sse/                     # Server-Sent Events writer/parser
│   │   ├── websocket/               # WebSocket handshake & frames
│   │   ├── multipart/               # Multipart form encoder/parser
│   │   ├── health/                  # Health check endpoints
│   │   ├── metrics/                 # Metrics registry
│   │   ├── auth/                    # Basic & Bearer auth helpers
│   │   └── watcher/                 # Live file watcher for dev reload
│   ├── protocols/
│   │   ├── http1/                   # HTTP/1.x parser & writer
│   │   ├── http2/                   # HTTP/2 frame, HPACK, transport
│   │   ├── http3/                   # HTTP/3 frame, connection
│   │   ├── quic/                    # QUIC varint, packet, crypto
│   │   ├── tls/                     # TLS 1.2/1.3, ALPN, server, QUIC-TLS
│   │   ├── ftp/                     # FTP client & server
│   │   └── common/                  # Shared protocol utilities
│   ├── net/
│   │   ├── resolve.zig              # DNS resolver with caching
│   │   ├── address.zig              # Network address abstraction
│   │   ├── socks5.zig               # SOCKS5 proxy tunneling
│   │   └── dns/                     # DNS protocol implementation
│   ├── sockets/
│   │   └── tcp.zig                  # Cross-platform TCP socket (IOCP/epoll)
│   ├── compression/                 # gzip, brotli, zstd, deflate
│   ├── concurrency/                 # WorkerPool, parallel requests
│   ├── parsing/                     # HTML/XML DOM, CSS selectors, feeds
│   │   ├── html.zig                 # HTML5 parser
│   │   ├── xml.zig                  # XML parser
│   │   ├── selector.zig             # CSS selector engine
│   │   ├── dom.zig                  # DOM tree traversal
│   │   ├── document.zig             # Document abstraction
│   │   ├── extract.zig              # Content extraction
│   │   ├── feed.zig                 # RSS/Atom/JSON feed parser
│   │   ├── robots.zig               # robots.txt parser
│   │   └── sitemap.zig              # Sitemap parser
│   ├── common/                      # Shared types: Method, Status, Headers, Logger
│   ├── utils/                       # MIME detection, helpers
│   └── assets/                      # Embedded UI assets (Swagger, ReDoc, GraphiQL)
├── examples/                        # 65 runnable examples
│   ├── simple_get.zig               # Basic HTTP GET
│   ├── post_json.zig                # POST with JSON body
│   ├── simple_server.zig            # Minimal HTTP server
│   ├── graphql_server.zig           # GraphQL + REST + OpenAPI
│   ├── tls_get.zig                  # HTTPS with TLS
│   ├── download.zig                 # File download with progress
│   └── ...                          # 60+ more (see examples/ dir)
├── bench/
│   └── main.zig                     # Microbenchmarks
├── docs/                            # VitePress documentation site
├── build.zig                        # Build system
├── build.zig.zon                    # Package metadata
├── README.md
├── SECURITY.md
├── LICENSE
└── CONTRIBUTING.md
```

## License

MIT License - see [LICENSE](LICENSE) for details.
