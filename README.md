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

<p><em>A Fast, High-Performance HTTP Client and Server Library for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/httpx.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/api/client">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`httpx.zig` is a modern, high-performance HTTP library for Zig, providing everything needed to build fast and reliable networked applications, including HTTP clients, servers, APIs, web services, reverse proxies, and full-featured websites.


> [!TIP]
> If you build with httpx.zig, make sure to give it a star.

> [!NOTE]
> **Project maturity:** This project is under active development. It provides a comprehensive HTTP client and server implementation with modern protocol, networking, security, and performance features, and contributions are welcome.
>
> **Custom HTTP/2, HTTP/3, TLS, Streaming, and Parsing implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, QUIC, ALPN negotiation, OpenAPI documentation UI, full HTML/XML DOM parsing, or built-in progress download engines.
> httpx.zig implements these subsystems **natively in Zig**, including:
> - **TLS 1.3 server engine + TLS 1.2/1.3 client** (RFC 5246 / RFC 8446) — a custom server-side TLS 1.3 engine (handshake, X25519 key exchange, ChaCha20-Poly1305 / AES-128-GCM / AES-256-GCM record encryption, ALPN negotiation per RFC 7301 with HTTP/1.1 fallback, X.509 parsing/verification, P-256 ECDSA certificates); the HTTPS *client* transport builds on `std.crypto.tls` (TLS 1.2/1.3) with httpx verification policy (SNI, SAN/hostname checks, system + custom trust stores)
> - **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
> - **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and HTTP/1.x connection pooling (RFC 7540; HTTP/2 connections are per-request for now)
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
- For **Tree-Sitter** support, check out **[tree-sitter.zig](https://github.com/muhammad-fiaz/tree-sitter.zig)**
---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Protocol Support** | Full client + server runtime across HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3: HTTP/2 over TCP/TLS with ALPN `h2`, stream multiplexing, flow control, SETTINGS, and trailers; HTTP/3 over QUIC/UDP with native TLS 1.3, ALPN `h3`, QPACK encoder/decoder streams, dynamic table management, request/response streaming, and TLS 1.3 0-RTT early-data resumption. |
| **Header Compression** | HPACK (RFC 7541) for HTTP/2; QPACK (RFC 9204) for HTTP/3 with static and dynamic table management. |
| **HTTP/2 & HTTP/3 ALPN** | Server-side ALPN negotiation during the TLS handshake with graceful HTTP/1.1 fallback; the native client offers ALPN too, so explicit `.http2` over TLS negotiates `h2` end to end, and `.http3` over QUIC negotiates `h3` end to end. |
| **Stream Multiplexing** | HTTP/2 and HTTP/3 stream state machines with flow control (WINDOW_UPDATE / MAX_STREAM_DATA), SETTINGS enforcement, GOAWAY/RST_STREAM, and trailers. |
| **Connection Pooling** | Automatic reuse of TCP keep-alive connections, multiplexed HTTP/2 and HTTP/3 connections, and TLS session resumption caching. |
| **Unified DOM & Web Parsing** | Native parser for HTML5, XML, RSS/Atom/JSON feeds, robots.txt, and sitemaps with zero-leak arena architecture. |
| **Streaming Downloader** | Resumable chunked file downloader powered by `loaders.zig` progress bars, ETA calculation, and hash verification. |
| **Pattern-based Routing** | Intuitive server routing with typed parameters (`/users/{id:int}`), slugs, catch-alls, groups, mounting, named routes + reversing, 404/405 handling, and OpenAPI integration. |
| **Middleware Stack** | Built-in middleware for CORS, security headers (Helmet), recovery, logging, rate limiting, and CSRF, plus health endpoints. |
| **TLS/SSL** | Native TLS 1.3 server engine + native TLS 1.3 client (RFC 8446) plus TLS 1.2/1.3 via the std-based HTTPS/1.1 transport: server ALPN (RFC 7301) with HTTP/1.1 fallback, native client ALPN (`h2` for HTTP/2 over TLS, `h3` for HTTP/3 over QUIC), X25519 ECDHE, AEAD ciphers, X.509 parsing/verification (P-256 ECDSA server certs), system/custom trust stores, hostname checks, mutual TLS enforcement (required/optional client certificates, presented via high-level `.tls = .{ .clientCertPem, .clientKeyPem }`), TLS 1.3 PSK session resumption (`psk_dhe_ke` NST tickets) + HelloRetryRequest, and complete TLS 1.3 0-RTT early data with bounded server-side anti-replay cache (`ReplayCache`) and safe HTTP method policy. |
| **Static Files & SPA** | High-performance static file serving with ETag, cache control, conditional GET, MIME detection, and SPA HTML5 fallback. |
| **Interactive API Docs** | Auto-generated OpenAPI 3.1 specifications with embedded Swagger UI, ReDoc, Scalar, and GraphiQL interfaces. |
| **Streaming & Realtime** | Chunked transfer responses with optional trailers, Server-Sent Events (SSE), and WebSocket frame support. |
| **Conditional Requests** | ETag and Last-Modified static file serving with `If-None-Match` revalidation. |
| **DNS Resolution** | Resolution with caching and concurrent resolver coalescing. |
| **Cookie APIs** | First-class request/response cookie jar and header helpers for both client and server contexts. |
| **Security & Hardening** | Security headers (Helmet), CSRF token helpers, and CRLF injection defenses. |
| **Multipart Form Data** | RFC 2046 streaming multipart body builder and parser for text fields and large file uploads. |
| **FTP & FTPS** | FTP client and server with PASV/EPSV, directory listing, streaming uploads/downloads, and resumption (explicit FTPS returns a typed error until TLS wiring lands). |
| **Concurrency & Workers** | Thread-safe bounded `WorkerPool` and parallel client requests (`getAll`, `requestAll`). |
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

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.16.0** (recommended) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

> [!IMPORTANT]
> **Zig 0.16.0 is required.** This project targets the stable Zig 0.16.0 release. Please use Zig 0.16.0 for all builds.

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

**Latest Release (v0.2.1)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.1.tar.gz
```

**Previous Release (v0.2.0)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.0.tar.gz
```

> [!WARNING]
> Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.16.0+** with **httpx.zig v0.2.1**.

### Method 2: Zig Fetch (Latest Development Build)

Use this for the latest development build from the `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.1.tar.gz",
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
    // 1. Primary unified fetch API (supports GET, POST, headers, typed JSON)
    var resp = try httpx.fetch("https://httpbun.com/get", .{});
    defer resp.deinit();
    std.debug.print("GET Status: {d}, Body: {s}\n", .{ resp.status, resp.bytes() });

    // 2. POST with strongly typed Zig struct (serialized via std.json)
    const CreateUser = struct { name: []const u8, email: []const u8 };

    var post = try httpx.fetch("https://httpbun.com/post", .{
        .method = .POST,
        .json = CreateUser{ .name = "Alice", .email = "alice@example.com" },
    });
    defer post.deinit();

    // 3. Strongly typed response decoding (httpbun echoes our JSON under "json")
    const Echo = struct { json: ?CreateUser = null };
    const echo = try post.json(Echo);
    if (echo.json) |user| std.debug.print("User: {s} <{s}>\n", .{ user.name, user.email });

    // 4. Convenience verb shortcuts
    var del = try httpx.delete("https://httpbun.com/delete", .{});
    defer del.deinit();
}
```


 ### Client Usage (Full Config)

HTTPX uses one consistent options-struct rule: fundamental inputs
(URL, host, source data) and long-lived resources (`allocator`, `io`)
stay positional; all configuration, behavior, limits, and settings go
inside the final `.{} ` argument:

```zig
client.get(url, .{ .timeoutMs = 10_000 });
client.resolve("httpbun.com", .{ .port = 443 });
```

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Create client with full config (all options use camelCase)
    var client = httpx.Client.init(allocator, io, .{
        .timeoutMs = 10_000,
        .followRedirects = true,
        .maxRedirects = 5,
        .maxRetries = 3,
        .retryDelayMs = 500,
        .retryStatusCodes = &.{ 502, 503, 504 },
        .dnsCache = .{ .enable = true, .ttlMs = 60_000 },
    });
    defer client.deinit();

    // Unified fetch request (GET)
    var response = try client.fetch("https://httpbun.com/get", .{});
    defer response.deinit();

    // Unified fetch request (POST with JSON)
    var post = try client.fetch("https://httpbun.com/post", .{
        .method = .POST,
        .json = .{ .name = "John", .role = "engineer" },
    });
    defer post.deinit();

    // HTTPS with TLS options
    var tls_resp = try client.fetch("https://httpbun.com/get", .{
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
// Parallel requests - getAll (arrays and slices accepted directly).
// Each Response must be deinited; the slice itself is freed with the
// caller's allocator (page_allocator for these global helpers).
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
var results = try httpx.getAll(urls);
defer {
    for (results) |*r| r.deinit();
    std.heap.page_allocator.free(results);
}

// Parallel requests - requestAll
const reqs = [_]httpx.RequestOptions{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
var batch = try httpx.requestAll(reqs);
defer {
    for (batch) |*r| r.deinit();
    std.heap.page_allocator.free(batch);
}
```


### File Downloads & Progress Reporting

`httpx.zig` includes a streaming download, resume, and file verification subsystem powered by `loaders.zig` for terminal progress bars:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const sampleUrl = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";

    // 1. Zero-config download with automatic filename & loaders.zig progress bar
    const res = try client.download(sampleUrl, .{
        .path = "downloads/",
        .progress = .auto,
        .existing = .overwrite,
        .createDirs = true,
    });
    std.debug.print("Downloaded: {s} ({d} bytes)\n", .{ res.destinationPath(), res.downloadedBytes });

    // 2. Download with in-flight cryptographic SHA-256 verification
    const verifiedRes = try client.download(sampleUrl, .{
        .path = "downloads/sample.pdf",
        .verify = .{
            .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .minSize = 100,
            .maxSize = 50 * 1024 * 1024,
        },
        .atomic = true, // downloads to temp file first, renames on valid hash
    });

    // 3. Inspect remote file metadata without downloading (size, filename, ranges)
    const fileInfo = try client.lookupFileInfo(sampleUrl, .{});
    var sizeStrBuf: [32]u8 = undefined;
    std.debug.print("Remote file: {s}, size: {s}\n", .{ fileInfo.fileName(), fileInfo.formatSize(&sizeStrBuf) });

    // 4. Resume partial download via HTTP Range: bytes=X- (clean non-reserved keyword name)
    const resumedRes = try client.download(sampleUrl, .{
        .path = "downloads/sample.pdf",
        .existing = .resumePartial,
        .maxRetries = 3,
    });

    // 5. Safe file updater with rollback backup
    const updateRes = try client.updateFile(sampleUrl, .{
        .path = "bin/app.bin",
        .backupExisting = true,
        .backupSuffix = ".bak",
    });

    // 6. Native FTP Download with progress
    const ftpRes = try httpx.ftp.download(allocator, .{
        .host = "ftp.example.com",
        .remotePath = "/pub/archive.tar.gz",
        .destinationPath = "downloads/",
        .progress = .auto,
    });
}
```

### Parsing & Inspection (Internal Tree-sitter & DOM Engine)

`httpx.zig` includes a comprehensive document parsing, DOM manipulation, and CSS selector inspection engine.

> [!NOTE]
> HTTPX parses HTML, XML, and templates with Tree-sitter grammars defined in their owning modules (`parsing/html.zig`, `parsing/xml.zig`, `web/templates/parser.zig`); DOM/AST semantics are built directly from those syntax trees. Applications interact exclusively with HTTPX's public APIs (`httpx.Parser`, `response.html()`, `doc.select()`). Tree-sitter is strictly an internal implementation detail and never needs to be imported by application code.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    // 1. Initialize unified parser with reusable allocator & configuration
    var p = httpx.Parser.init(allocator, .{});

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
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .portStrategy = .incremental, // auto-increments port (8081, 8082, ...) if 8080 is busy
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

fn handler(_: httpx.tls.Request) anyerror!httpx.tls.Response {
    return .{ .body = "Hello over TLS!" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var tls_listener = try httpx.tls.Listener.init(allocator, io, .{
        .port = 8443,
        .defaultIdentity = .{
            .certChainPem = @embedFile("cert.pem"),
            .privateKeyPem = @embedFile("key.pem"),
        },
    });
    defer tls_listener.deinit();

    // Blocking accept loop — use requestShutdown() to break out
    try tls_listener.run(handler);
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

## Server Metrics & Prometheus Observability

HTTPX servers feature dynamic Prometheus v0.0.4 text exposition and thread-safe snapshots:

```zig
// Mount dynamic Prometheus endpoint
try server.metrics("/metrics");

// Query point-in-time server snapshot (zero-allocation)
const snap = server.snapshot();
std.debug.print("Uptime: {d}ms, Requests: {d}, Errors: {d}, Error Rate: {d:.2}%\n", .{
    snap.uptimeMs,
    snap.requestsTotal,
    snap.errorsTotal,
    snap.errorRate() * 100.0,
});

// Query point-in-time metrics snapshot
const m_snap = server.metricsSnapshot();
std.debug.print("Avg Latency: {d:.3}ms\n", .{m_snap.averageLatencyMs()});
```

Visiting `/metrics` provides standard Prometheus metrics:
- `http_requests_total`, `http_responses_total`, `http_errors_total`, `http_timeouts_total`
- `http_bytesIn_total`, `http_bytesOut_total`
- `http_active_connections`, `http_active_requests`
- `http_requests_by_method_total{method="..."}`, `http_responses_by_status_total{status="..."}`
- `http_request_duration_seconds_bucket{le="..."}`, `_sum`, `_count`

## Live File Watcher & Reload Engine

Native OS events (ReadDirectoryChangesW / inotify / kqueue) with recursive watching and rename pairing. The walk prunes generated trees (`node_modules`, `.git`, `.zig-cache`, `zig-out`, `zig-pkg`, `.cache`, `dist`) at any depth, so watching a repository root does not drown in dependency files.

Each changed file is classified into a reload strategy, and the browser client acts on it over SSE:

| Change | Strategy | Browser behaviour |
| --- | --- | --- |
| `.css` | `hotReload` | Stylesheet `<link>`s are cache-busted and refetched in place; no document reload, no lost script state |
| `.html`, `.htm`, templates, assets | `warmReload` | Document reload |
| `.json`, `.env`, `.toml`, `.yaml`, `.conf` | `coldReload` | Document reload |
| `.zig` | `restart` | Document reload |

Setting `liveReload = true` on the server wires it up for you: the SSE endpoint is mounted at `liveReloadPath`, and the client script is injected into every HTML response — handler-written pages, static files, and the site generator alike.

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .liveReload = true,      // SSE endpoint + client injection
    .watch = true,           // watch watchDir
    .watchDir = "./public",
});
```

`onChange` is invoked on the watcher thread with no internal lock held, so a callback may safely call `next()`, `changeCount()`, or `stop()`:

```zig
var watcher = try httpx.static.Watcher.init(allocator, io, .{
    .dirPath = "./public",
    .pollIntervalMs = 50,
    .onChange = onFileChanged,
});
defer watcher.deinit();

try watcher.start();
```

If you build the page yourself, the same script is available directly:

```zig
const html = try httpx.static.reload.inject(allocator, body, "/__httpx_liveReload");
```

## TLS Listener Lifecycle

```zig
// Blocking accept loop
try tls_listener.run(handler);

// Graceful shutdown (via the wrapped server)
tls_listener.server.requestShutdown();

// Immediate shutdown
tls_listener.stop();
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
var client = httpx.Client.init(allocator, io, .{
    .maxRetries = 3,                // retry up to 3 times (4 total attempts)
    .retryDelayMs = 500,            // base delay between retries
    .retryStatusCodes = &.{ 502, 503, 504 }, // status codes that trigger retry
});
```

The delay between retries increases linearly: `retryDelayMs * (attempt + 1)`.

## DNS Resolution

```zig
var resolver = httpx.resolve.Resolver.init(allocator, io);
const addrs = try resolver.lookup("example.com", .{ .port = 443 });
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
- [`simple_get`](examples/simpleGet.zig) - Basic GET requests
- [`post_json`](examples/postJson.zig) - POST with JSON body
- [`custom_headers`](examples/customHeaders.zig) - Custom header management
- [`connection_pool`](examples/connectionPool.zig) - Connection pooling and stats
- [`redirect`](examples/redirect.zig) - Redirect handling
- [`http10_client`](examples/http10Client.zig) - HTTP/1.0 client
- [`tls_get`](examples/tlsGet.zig) - HTTPS client with TLS
- [`https_client`](examples/httpsClient.zig) - HTTPS client with TLS
- [`tls12_client`](examples/tls12Client.zig) - TLS 1.2 with self-signed cert
- [`tls13_client`](examples/tls13Client.zig) - TLS 1.3 with self-signed cert
- [`tls_mtls`](examples/tlsMtls.zig) - Mutual TLS (mTLS)
- [`resolve`](examples/resolve.zig) - DNS resolution
- [`concurrent_demo`](examples/concurrentDemo.zig) - Parallel request patterns
- [`proxy_demo`](examples/proxyDemo.zig) - HTTP forward proxy
- [`dns_demo`](examples/dnsDemo.zig) - DNS resolution and IP checks
- [`dns_cache`](examples/dnsCache.zig) - DNS caching
- [`compression_demo`](examples/compressionDemo.zig) - gzip/deflate/brotli compression
- [`retry_demo`](examples/retryDemo.zig) - Retry with exponential backoff
- [`http11_client`](examples/http11Client.zig) - HTTP/1.1 client
- [`connectivity`](examples/connectivity.zig) - Online checks and connectivity probes
- [`browser_demo_server`](examples/browserDemoServer.zig) - Browser demo server
- [`full_integration`](examples/fullIntegration.zig) - Full client/server integration

**Server:**
- [`simple_server`](examples/simpleServer.zig) - Minimal HTTP server
- [`custom_responses`](examples/customResponses.zig) - Rich response generation (HTML, JSON, XML, RSS, Atom, robots.txt, sitemap.xml, binary)
- [`static_files`](examples/staticFiles.zig) - Static file serving with ETag
- [`health_check`](examples/healthCheck.zig) - Liveness/readiness probes
- [`streaming`](examples/streaming.zig) - Chunked transfer and SSE
- [`auth_and_errors`](examples/authAndErrors.zig) - Authentication and error handling
- [`live_static_watcher`](examples/liveStaticWatcher.zig) - Live file watcher and auto-reload
- [`docs_server`](examples/docsServer.zig) - Swagger UI, ReDoc, Scalar, GraphiQL
- [`graphql_server`](examples/graphqlServer.zig) - GraphQL server
- [`spa_fallback`](examples/spaFallback.zig) - SPA with HTML/JS/CSS and client-side routing
- [`websocket_server`](examples/websocketServer.zig) - WebSocket server
- [`sse_server`](examples/sseServer.zig) - Server-Sent Events
- [`session_server`](examples/sessionServer.zig) - TTL-based session management
- [`metrics_server`](examples/metricsServer.zig) - Prometheus metrics
- [`interceptor_example`](examples/interceptorExample.zig) - Request/response interceptors
- [`cookie_server`](examples/cookieServer.zig) - Cookie management
- [`cors_server`](examples/corsServer.zig) - CORS configuration
- [`helmet_server`](examples/helmetServer.zig) - Security headers (Helmet)
- [`rate_limit_server`](examples/rateLimitServer.zig) - Rate limiting
- [`body_parser_server`](examples/bodyParserServer.zig) - Request body parsing
- [`custom_server`](examples/customServer.zig) - Request ID and body parsing
- [`tls_server`](examples/tlsServer.zig) - HTTPS/TLS server with self-signed cert
- [`ftp_server`](examples/ftpServer.zig) - FTP-like server
- [`http11_server`](examples/http11Server.zig) - HTTP/1.1 server
- [`routing_demo`](examples/routingDemo.zig) - Typed routing, groups, mounts, reversing
- [`static_embedded`](examples/staticEmbedded.zig) - Embedded-asset serving

**Download & File Inspection:**
- [`download`](examples/download.zig) - Download with built-in progress bar and destination inference
- [`download_batch`](examples/downloadBatch.zig) - Concurrent worker pool batch downloads
- [`download_resume`](examples/downloadResume.zig) - Range-based resumption
- [`download_verify`](examples/downloadVerify.zig) - Cryptographic verification (SHA-256, SHA-384, SHA-512, MD5, SHA-1)
- [`download_checksum_file`](examples/downloadChecksumFile.zig) - Remote checksum file lookup and verification
- [`download_existing`](examples/downloadExisting.zig) - Existing file policies (fail, overwrite, skip, resume, replace_if_changed)
- [`download_update`](examples/downloadUpdate.zig) - Atomic self-updates with rollback safety
- [`download_info`](examples/downloadInfo.zig) - Metadata HEAD inspection without full body download
- [`download_custom_progress`](examples/downloadCustomProgress.zig) - Custom progress tracking and observers
- [`ftp_download`](examples/ftpDownload.zig) - Direct FTP file download

**Parsing & Inspection (Internal Tree-sitter & DOM Engine):**
- [`html_client`](examples/htmlClient.zig) - Client fetch and automatic `response.html()` parsing
- [`html_select`](examples/htmlSelect.zig) - CSS selector engine queries (`tag`, `.class`, `#id`, `[attr]`, combinators)
- [`html_extract`](examples/htmlExtract.zig) - High-level extraction helpers (title, text, links, forms, images)
- [`html_stream`](examples/htmlStream.zig) - Streaming reader input parsing
- [`html_file`](examples/htmlFile.zig) - HTML file parsing and node inspection
- [`html_transform`](examples/htmlTransform.zig) - Structural mutation, attribute updating, and XSS-safe serialization
- [`parse_html`](examples/parseHtml.zig) - HTML DOM, CSS Selectors, RSS feeds, robots.txt, and sitemaps

**File Watching, Static Assets & Live Reload:**
- [`file_watcher`](examples/fileWatcher.zig) - OS-native file monitoring (Windows ReadDirectoryChangesW, Linux inotify, macOS kqueue) with rename pairing and browser live reload
- [`live_reload`](examples/liveReload.zig) - Live reload dev server with CSS hot reload vs HTML page reload
- [`static_site`](examples/staticSite.zig) - Static site directory mounting with ETag caching and conditional GET
- [`spa_server`](examples/spaServer.zig) - Single Page Application server with client-side route fallback
- [`development_server`](examples/developmentServer.zig) - Unified dev server combining watcher, live reload, and incremental parsing


**Protocol:**
- [`http2_client`](examples/http2Client.zig) - HTTP/2 client
- [`http2_multiplex`](examples/http2Multiplex.zig) - HTTP/2 stream multiplexing
- [`http2_tls`](examples/http2Tls.zig) - HTTP/2 over TLS with ALPN + chain verification
- [`http3_client`](examples/http3Client.zig) - HTTP/3 client
- [`http3_quic`](examples/http3Quic.zig) - HTTP/3 over QUIC

**Templates & Website:**
- [`web/templates/basic`](examples/web/templates/basic/main.zig) - Basic template rendering
- [`web/templates/inheritance`](examples/web/templates/inheritance/main.zig) - Template inheritance
- [`web/templates/loops`](examples/web/templates/loops/main.zig) - Template loops
- [`web/templates/includes`](examples/web/templates/includes/main.zig) - Template includes
- [`web/templates/live_reload`](examples/web/templates/live_reload/main.zig) - Live-reload templates
- [`web/templates/jinja`](examples/web/templates/jinja/main.zig) - Flask-style templates (extends, blocks, includes, macros, filters)
- [`website`](examples/website/main.zig) - Full website with embedded assets

**Advanced:**
- [`multipart`](examples/multipart.zig) - Multipart form data
- [`openapi`](examples/openapi.zig) - OpenAPI spec generation
- [`ftp_client`](examples/ftpClient.zig) - FTP client


**Static Assets (for SPA example):**
- [`static/index.html`](examples/static/index.html) - Main HTML page
- [`static/about.html`](examples/static/about.html) - About page
- [`static/contact.html`](examples/static/contact.html) - Contact page with form
- [`static/styles.css`](examples/static/styles.css) - CSS styles
- [`static/app.js`](examples/static/app.js) - Client-side JavaScript

To run any example:
```bash
zig build run-<example-name>
# e.g., zig build run-simple-get
# e.g., zig build run-spa-fallback
```


## Validation Matrix

```bash
# Host runtime validation
zig build test
zig build run-all-examples   # Runs sequentially to prevent parallel compiler OOM

# Cross-target library compile validation
zig build build-all-examples -Dtarget=x86_64-linux-gnu
```

To validate Linux runtime behavior, run the cross-compiled artifacts on Linux/WSL (a foreign-target `zig build test` only compiles; it does not execute):

```bash
zig build test -Dtarget=x86_64-linux-gnu
zig build run-simple-get -Dtarget=x86_64-linux-gnu
```

For explicit cross-target compilation:

```bash
# Compile tests for 32-bit Windows
zig build test -Dtarget=x86-windows-gnu

# Compile an example for macOS ARM64
zig build run-simple-get -Dtarget=aarch64-macos
```

## Performance

Run benchmarks:

```bash
zig build bench
```

Benchmark target: `x86_64-windows`, `ReleaseFast` (measured 2026-10-02).

| Benchmark | Category | Avg Latency | Throughput | Target |
| :--- | :--- | :---: | :---: | :---: |
| `headers_parse` | Core Operations | 365.64 ns/op | **2734908 ops/sec** | `x86_64-windows` |
| `uri_parse` | Core Operations | 33.81 ns/op | **29580460 ops/sec** | `x86_64-windows` |
| `status_lookup` | Core Operations | 2.68 ns/op | **372929773 ops/sec** | `x86_64-windows` |
| `method_lookup` | Core Operations | 21.66 ns/op | **46168073 ops/sec** | `x86_64-windows` |
| `http1_request_head` | Core Operations | 23.55 ns/op | **42454372 ops/sec** | `x86_64-windows` |
| `http1_header_block` | Core Operations | 257.05 ns/op | **3890293 ops/sec** | `x86_64-windows` |
| `router_static_match` | Routing | 1.24 ┬╡s/op | **806411 ops/sec** | `x86_64-windows` |
| `router_param_match` | Routing | 1.25 ┬╡s/op | **801630 ops/sec** | `x86_64-windows` |
| `router_dispatch` | Routing | 1.26 ┬╡s/op | **795854 ops/sec** | `x86_64-windows` |
| `router_typed_match` | Routing | 1.54 ┬╡s/op | **647704 ops/sec** | `x86_64-windows` |
| `router_miss_404` | Routing | 2.00 ┬╡s/op | **500509 ops/sec** | `x86_64-windows` |
| `router_reverse` | Routing | 83.98 ns/op | **11908206 ops/sec** | `x86_64-windows` |
| `json_stringify` | Serialization | 276.36 ns/op | **3618459 ops/sec** | `x86_64-windows` |
| `json_parse` | Serialization | 343.94 ns/op | **2907485 ops/sec** | `x86_64-windows` |
| `basic_auth_encode` | Security | 25.63 ns/op | **39014646 ops/sec** | `x86_64-windows` |
| `basic_auth_decode` | Security | 23.96 ns/op | **41737794 ops/sec** | `x86_64-windows` |
| `bearer_token_parse` | Security | 10.96 ns/op | **91241791 ops/sec** | `x86_64-windows` |
| `gzip_compress` | Compression | 76.54 ┬╡s/op | **13065 ops/sec** | `x86_64-windows` |
| `gzip_decompress` | Compression | 11.19 ┬╡s/op | **89353 ops/sec** | `x86_64-windows` |
| `deflate_compress` | Compression | 50.75 ┬╡s/op | **19702 ops/sec** | `x86_64-windows` |
| `deflate_decompress` | Compression | 6.65 ┬╡s/op | **150313 ops/sec** | `x86_64-windows` |
| `html_parse` | Parsing | 19.21 ┬╡s/op | **52057 ops/sec** | `x86_64-windows` |
| `template_parse` | Parsing | 2.90 ┬╡s/op | **345276 ops/sec** | `x86_64-windows` |
| `template_render` | Parsing | 1.53 ┬╡s/op | **651719 ops/sec** | `x86_64-windows` |
| `template_incremental` | Parsing | 20.60 ┬╡s/op | **48548 ops/sec** | `x86_64-windows` |
| `json_feed_parse` | Parsing | 4.06 ┬╡s/op | **246242 ops/sec** | `x86_64-windows` |
| `live_reload_inject` | Parsing | 453.54 ns/op | **2204869 ops/sec** | `x86_64-windows` |
| `watcher_scan` | Watcher | 1.15 ms/op | **873 ops/sec** | `x86_64-windows` |
| `watcher_deps` | Watcher | 3.87 ┬╡s/op | **258305 ops/sec** | `x86_64-windows` |
| `worker_pool_submit` | Concurrency | 218.84 ns/op | **4569510 ops/sec** | `x86_64-windows` |
| `concurrency_queue` | Concurrency | 42.82 ns/op | **23353082 ops/sec** | `x86_64-windows` |
| `dns_cache_hit` | DNS | 54.96 ns/op | **18196507 ops/sec** | `x86_64-windows` |
| `h2_frame_header` | Protocols | 1.14 ns/op | **873835614 ops/sec** | `x86_64-windows` |
| `hpack_int_encode` | Protocols | 0.91 ns/op | **1095338240 ops/sec** | `x86_64-windows` |
| `hpack_int_decode` | Protocols | 1.50 ns/op | **668127639 ops/sec** | `x86_64-windows` |
| `h3_varint_encode` | Protocols | 1.82 ns/op | **550518312 ops/sec** | `x86_64-windows` |
| `h3_varint_decode` | Protocols | 1.78 ns/op | **562667041 ops/sec** | `x86_64-windows` |
| `tls_record_seal` | TLS | 1.52 ┬╡s/op | **658921 ops/sec** | `x86_64-windows` |
| `tls_cert_parse` | TLS | 1.05 ┬╡s/op | **955103 ops/sec** | `x86_64-windows` |
| `client_server_get` | Network | 385.93 ┬╡s/op | **2591 req/sec** | `x86_64-windows` |
| `h2_pooled_get` | Network | 53.50 ┬╡s/op | **18691 req/sec** | `x86_64-windows` |
| `h3_get` | Network | 206.05 ms/op | **4 req/sec** | `x86_64-windows` |
| `tls_full_handshake` | TLS | 4.34 ms/op | **230 ops/sec** | `x86_64-windows` |
| `tls_resumed_handshake` | TLS | 2.82 ms/op | **354 ops/sec** | `x86_64-windows` |

See [docs/reference/benchmarks.md](docs/reference/benchmarks.md) for full methodology and detailed analysis.

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
│   │   ├── templates/               # Flask-style template engine (Tree-sitter syntax, cached AST)
│   │   ├── site/                    # File-based website routing
│   │   ├── watcher/                 # File watcher + browser live-reload client
│   │   ─   ─   ─   ─   backend.zig          # Watcher facade, index, queue, debounce
│   │   ─   ─   ─   ─   events.zig           # Event model, classification, coalescing
│   │   ─   ─   ─   ─   client.zig           # Browser-side SSE live-reload script
│   │   ─   ─   ─   ─   dependency.zig       # Dependency graph for reload invalidation
│   │   ─   ─   ─   ─   windows/linux/macos.zig  # Native backends (RDC/inotify/kqueue)
│   ├── protocols/
│   │   ├── http1/                   # HTTP/1.x parser & writer
│   │   ├── http2/                   # HTTP/2 frame, HPACK, transport
│   │   ├── http3/                   # HTTP/3 frame, connection
│   │   ├── quic/                    # QUIC varint, packet, crypto
│   │   ├── tls/                     # TLS 1.3 server engine + native client, QUIC-TLS, ALPN, mTLS
│   │   ├── ftp/                     # FTP client & server
│   │   └── common/                  # Shared protocol utilities
│   ├── net/
│   │   ├── resolve.zig              # DNS resolver with caching
│   │   ├── address.zig              # Network address abstraction
│   │   ├── socks5.zig               # SOCKS5/5h proxy tunneling
│   │   ├── socks4.zig               # SOCKS4/4a proxy tunneling
│   │   ├── proxy.zig                # HTTP proxy support
│   │   ├── connectivity.zig         # Connectivity probing
│   │   └── dns/                     # DNS protocol + cache
│   ├── sockets/
│   │   ├── tcp.zig                  # Cross-platform TCP socket (IOCP/epoll)
│   │   ├── udp.zig                  # UDP socket
│   │   └── sys.zig                  # Raw syscall layer + error mapping
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
│   ├── common/                      # Method, Status, Headers, URI, Logger, clock
│   ├── utils/                       # MIME detection (mime.zig), filesystem helpers (fs.zig)
│   └── assets/                      # Embedded UI assets (Swagger, ReDoc, GraphiQL)
├── examples/                        # 80+ runnable examples
│   ├── simpleGet.zig               # Basic HTTP GET
│   ├── postJson.zig                # POST with JSON body
│   ├── simpleServer.zig            # Minimal HTTP server
│   ├── graphqlServer.zig           # GraphQL + REST + OpenAPI
│   ├── tlsGet.zig                  # HTTPS with TLS
│   ├── download.zig                 # File download with progress
│   └── ...                          # 70+ more (see examples/ dir)
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

