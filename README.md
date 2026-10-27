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

## Why httpx.zig

> [!IMPORTANT]
> Zig's standard library provides `std.http` for HTTP client and server functionality. Projects that need a broader range of HTTP protocols, networking features, or web framework capabilities may need to integrate additional libraries or implement the missing functionality themselves.
>
> httpx.zig brings these capabilities together in one native Zig library, with support for HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3, alongside networking, TLS integration, DNS, proxies, connection management, cookies, middleware, static-file serving, WebSocket functionality, multipart processing, and streaming downloads.
>
> The library focuses on a clean, modular API with explicit allocator and I/O ownership, predictable resource lifetimes, and consistent error handling. The client API has been rewritten to remove unnecessary convenience functions, redundant entry points, and duplicate abstractions in favor of a clearer `httpx.Client` workflow. Configuration and environment access are explicit, giving applications greater control over initialization and runtime behavior.
>
> Whether you're building an API client, a web service, a download manager, or an application that needs support across multiple HTTP versions, httpx.zig aims to provide a consistent foundation without requiring you to assemble every component separately.
>
> For smaller projects that only need the functionality available in Zig's standard library, `std.http` may be sufficient. For a broader HTTP stack and integrated web framework, explore what httpx.zig offers.
>
> **Refer to the [documentation](./docs/) for installation, usage examples, API references, supported features, and migration guidance.** Review the breaking changes before upgrading, particularly those affecting client APIs, initialization, allocator and I/O ownership, and configuration.
>
> The project is actively developed, and contributions, bug reports, and improvements are welcome.

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
| **Concurrency & Workers** | Thread-safe bounded `httpx.concurrency.Pool` and parallel client requests (`getAll`, `requestAll`). |
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
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

> [!IMPORTANT]
> **Zig 0.17.0 is required.** This project targets the stable Zig 0.17.0 release. Please use Zig 0.17.0 for all builds. Zig 0.16.0 is not supported by this release.

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

**Latest Release (v0.2.3)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.3.tar.gz
```

**Previous Release (v0.2.2)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.2.tar.gz
```

> [!WARNING]
> Zig **0.17** is required by **v0.2.3**. Zig **0.16** is deprecated and supported only by **v0.2.1**, and Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.17.0+** with **httpx.zig v0.2.3**.

### Method 2: Zig Fetch (Latest Development Build)

Use this for the latest development build from the `main` branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.3.tar.gz",
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

Initialize an `httpx.Client` with your allocator and I/O context. The client provides built-in connection pooling, TLS session resumption, and DNS caching:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize client
    var client = httpx.Client.init(allocator, io, .{
        .timeoutMs = 10_000,
        .followRedirects = true,
        .maxRedirects = 5,
        .dnsCache = .{ .enable = true, .ttlMs = 60_000 },
    });
    defer client.deinit();

    // 2. GET request
    var res = try client.get("https://httpbun.com/get", .{});
    defer res.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res.status, res.text() });

    // 3. POST with strongly-typed JSON payload
    const User = struct { name: []const u8, role: []const u8 };
    var postRes = try client.postJson("https://httpbun.com/post", User{
        .name = "Alice",
        .role = "engineer",
    }, .{});
    defer postRes.deinit();
}
```

### Stateful Client Operations

Execute standard HTTP methods and advanced requests across shared connections:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Initialize stateful client
    var client = httpx.Client.init(allocator, io, .{
        .timeoutMs = 10_000,
        .followRedirects = true,
        .maxRedirects = 5,
        .dnsCache = .{ .enable = true, .ttlMs = 60_000 },
    });
    defer client.deinit();

    // Standard HTTP methods
    var getRes = try client.get("https://httpbun.com/get", .{});
    defer getRes.deinit();

    var postRes = try client.post("https://httpbun.com/post", .{
        .body = "hello=world",
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
    });
    defer postRes.deinit();

    // Strongly-typed JSON serialization & deserialization
    const CreateUser = struct { name: []const u8, email: []const u8 };
    var userRes = try client.postJson("https://httpbun.com/post", CreateUser{
        .name = "Alice",
        .email = "alice@example.com",
    }, .{});
    defer userRes.deinit();

    const Echo = struct { json: ?CreateUser = null };
    const echo = try userRes.json(Echo);
    if (echo.json) |user| std.debug.print("Created: {s} <{s}>\n", .{ user.name, user.email });

    // Additional HTTP verbs
    var putRes = try client.put("https://httpbun.com/put", .{ .body = "updated" });
    defer putRes.deinit();

    var patchRes = try client.patch("https://httpbun.com/patch", .{ .body = "partial" });
    defer patchRes.deinit();

    var delRes = try client.delete("https://httpbun.com/delete", .{});
    defer delRes.deinit();
}
```

### 3. Fluent RequestBuilder

For advanced request assembly with headers, query parameters, authorization, and timeouts:

```zig
var builder = client.requestBuilder(.POST, "https://httpbun.com/post");
defer builder.deinit();

_ = try builder.header("X-API-Key", "secret-token-123");
_ = try builder.query("filter", "active");
_ = builder.timeoutMs(5000);
_ = builder.bearerAuth("jwt-token-xyz");
_ = try builder.json(.{ .query = "search term", .page = @as(u32, 1) });

var res = try builder.send();
defer res.deinit();
std.debug.print("Response: {d} {s}\n", .{ res.status, res.text() });
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
// Each Response must be deinited; free the slice with the client's allocator.
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
var results = try client.getAll(urls);
defer {
    for (results) |*r| r.deinit();
    allocator.free(results);
}

// Parallel requests - requestAll
const reqs = .{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
var batch = try client.requestAll(reqs);
defer {
    for (batch) |*r| r.deinit();
    allocator.free(batch);
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
    const ftpRes = try httpx.client.download.ftpDownload(io, allocator, .{
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
> HTTPX parses HTML, XML, and templates with Tree-sitter grammars defined in their owning modules (`parsing/html.zig`, `parsing/xml.zig`, `web/templates/parser.zig`); DOM/AST semantics are built directly from those syntax trees. Applications interact exclusively with HTTPX's public APIs (`httpx.parsing.Parser`, `response.html()`, `doc.select()`). Tree-sitter is strictly an internal implementation detail and never needs to be imported by application code.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    // 1. Initialize unified parser with reusable allocator & configuration
    var p = httpx.parsing.Parser.init(allocator, .{});

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

fn hello(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.renderJson(.{ .message = "Hello!" });
}

fn page(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
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

### Modern App Facade & Zig-Native REST Framework

`httpx.zig` provides a high-level `App` facade and a type-driven `Rest` subsystem. REST routes automatically bind request payloads, execute typed handlers, serialize response structs to JSON, and derive an OpenAPI 3.1 specification via compile-time reflection.

```zig
const std = @import("std");
const httpx = @import("httpx");

const CreateItemRequest = struct {
    name: []const u8,
    price: u64,
};

const ItemResponse = struct {
    id: u64,
    name: []const u8,
    price: u64,
};

fn createItem(ctx: *httpx.router.Context, req: CreateItemRequest) !httpx.ApiResult(ItemResponse) {
    _ = ctx;
    return .created(.{
        .id = 101,
        .name = req.name,
        .price = req.price,
    });
}

fn getItem(ctx: *httpx.router.Context, req: struct { id: u64 }) !httpx.ApiResult(ItemResponse) {
    _ = ctx;
    return .ok(.{
        .id = req.id,
        .name = "Widget",
        .price = 499,
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var app = try httpx.App.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
    });
    defer app.deinit();

    // Register typed REST endpoints (drives router + OpenAPI 3.1 schema)
    try app.restPost("/api/items", createItem);
    try app.restGet("/api/items/{id}", getItem);

    // Mount interactive documentation UIs with local embedded vendor assets
    try app.docs(.{
        .openapi = .{ .enabled = true, .path = "/openapi.json", .title = "Items API", .version = "1.0.0" },
        .swaggerUi = .{ .enabled = true, .path = "/docs" },
        .redoc = .{ .enabled = true, .path = "/redoc" },
        .scalar = .{ .enabled = true, .path = "/scalar" },
    });

    try app.run();
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
var resolver = httpx.net.resolve.Resolver.init(allocator, io);
const addrs = try resolver.lookup("example.com", .{ .port = 443 });
defer allocator.free(addrs);
```

## Context Methods & Response Types

```zig
fn handler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
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
- [`retry_demo`](examples/retryDemo.zig) - Client retries with linear backoff
- [`http11_client`](examples/http11Client.zig) - HTTP/1.1 client
- [`connectivity`](examples/connectivity.zig) - Online checks and connectivity probes
- [`browser_demo_server`](examples/browserDemoServer.zig) - Browser demo server
- [`full_integration`](examples/fullIntegration.zig) - Full client/server integration

**Server:**
- [`simple_server`](examples/simpleServer.zig) - Minimal HTTP server
- [`rest_api`](examples/restApi.zig) - Typed REST endpoints with automatic OpenAPI 3.1 & Docs
- [`custom_responses`](examples/customResponses.zig) - Rich response generation (HTML, JSON, XML, RSS, Atom, robots.txt, sitemap.xml, binary)
- [`static_files`](examples/staticFiles.zig) - Static file serving with ETag
- [`health_check`](examples/healthCheck.zig) - Liveness/readiness probes
- [`streaming`](examples/streaming.zig) - Buffered response reader (plus SSE examples)
- [`auth_and_errors`](examples/authAndErrors.zig) - Authentication and error handling
- [`live_static_watcher`](examples/liveStaticWatcher.zig) - Live file watcher and auto-reload
- [`docs_server`](examples/docsServer.zig) - Swagger UI, ReDoc, Scalar, GraphiQL
- [`graphql_server`](examples/graphqlServer.zig) - GraphQL server
- [`spa_fallback`](examples/spaFallback.zig) - SPA with HTML/JS/CSS and client-side routing
- [`websocket_server`](examples/websocketServer.zig) - WebSocket server
- [`sse_server`](examples/sseServer.zig) - Server-Sent Events
- [`session_server`](examples/sessionServer.zig) - Cookie-backed session flow
- [`metrics_server`](examples/metricsServer.zig) - Prometheus metrics
- [`interceptor_example`](examples/interceptorExample.zig) - Client request wrappers around a server route
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
- [`liveReload`](examples/liveReload.zig) - Live reload dev server with CSS hot reload vs HTML page reload
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
- [`web/templates/liveReload`](examples/web/templates/liveReload/main.zig) - Live-reload templates
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

## Examples

The [`examples/`](examples) directory contains runnable examples demonstrating all features of `httpx.zig`.

To run any example:
```sh
zig build run-<example-name>
# Examples:
#   zig build run-simple-get
#   zig build run-spa-fallback
#   zig build run-download
#   zig build run-rest-api
```

### Core Client Examples
- [`simple_get`](examples/simpleGet.zig) — Basic GET requests
- [`post_json`](examples/postJson.zig) — POST with JSON body
- [`custom_headers`](examples/customHeaders.zig) — Custom header management
- [`connection_pool`](examples/connectionPool.zig) — Connection pooling and stats
- [`redirect`](examples/redirect.zig) — Redirect handling
- [`http10_client`](examples/http10Client.zig) — HTTP/1.0 client
- [`http11_client`](examples/http11Client.zig) — HTTP/1.1 client
- [`tls_get`](examples/tlsGet.zig) — HTTPS client with TLS
- [`https_client`](examples/httpsClient.zig) — HTTPS client with TLS
- [`retry_demo`](examples/retryDemo.zig) — Client retries with linear backoff
- [`concurrent_demo`](examples/concurrentDemo.zig) — Parallel request patterns

<details>
<summary><strong>Server & Web API Examples</strong> (Click to expand)</summary>

- [`simple_server`](examples/simpleServer.zig) — Minimal HTTP server
- [`rest_api`](examples/restApi.zig) — Typed REST endpoints with automatic OpenAPI 3.1 & Docs
- [`custom_responses`](examples/customResponses.zig) — Rich response generation (HTML, JSON, XML, RSS, Atom, robots.txt, sitemap.xml, binary)
- [`static_files`](examples/staticFiles.zig) — Static file serving with ETag
- [`health_check`](examples/healthCheck.zig) — Liveness/readiness probes
- [`streaming`](examples/streaming.zig) — Buffered response reader (plus SSE examples)
- [`auth_and_errors`](examples/authAndErrors.zig) — Authentication and error handling
- [`live_static_watcher`](examples/liveStaticWatcher.zig) — Live file watcher and auto-reload
- [`docs_server`](examples/docsServer.zig) — Swagger UI, ReDoc, Scalar, GraphiQL
- [`graphql_server`](examples/graphqlServer.zig) — GraphQL server
- [`spa_fallback`](examples/spaFallback.zig) — SPA with HTML/JS/CSS and client-side routing
- [`websocket_server`](examples/websocketServer.zig) — WebSocket server
- [`sse_server`](examples/sseServer.zig) — Server-Sent Events
- [`session_server`](examples/sessionServer.zig) — Cookie-backed session flow
- [`metrics_server`](examples/metricsServer.zig) — Prometheus metrics
- [`interceptor_example`](examples/interceptorExample.zig) — Client request wrappers around a server route
- [`cookie_server`](examples/cookieServer.zig) — Cookie management
- [`cors_server`](examples/corsServer.zig) — CORS configuration
- [`helmet_server`](examples/helmetServer.zig) — Security headers (Helmet)
- [`rate_limit_server`](examples/rateLimitServer.zig) — Rate limiting
- [`body_parser_server`](examples/bodyParserServer.zig) — Request body parsing
- [`custom_server`](examples/customServer.zig) — Request ID and body parsing
- [`tls_server`](examples/tlsServer.zig) — HTTPS/TLS server with self-signed cert
- [`ftp_server`](examples/ftpServer.zig) — FTP-like server
- [`http11_server`](examples/http11Server.zig) — HTTP/1.1 server
- [`routing_demo`](examples/routingDemo.zig) — Typed routing, groups, mounts, reversing
- [`static_embedded`](examples/staticEmbedded.zig) — Embedded-asset serving
- [`browser_demo_server`](examples/browserDemoServer.zig) — Browser demo server
- [`full_integration`](examples/fullIntegration.zig) — Full client/server integration
</details>

<details>
<summary><strong>Download & File Inspection Examples</strong> (Click to expand)</summary>

- [`download`](examples/download.zig) — Download with built-in progress bar and destination inference
- [`download_batch`](examples/downloadBatch.zig) — Concurrent worker pool batch downloads
- [`download_resume`](examples/downloadResume.zig) — Range-based resumption
- [`download_verify`](examples/downloadVerify.zig) — Cryptographic verification (SHA-256, SHA-384, SHA-512, MD5, SHA-1)
- [`download_checksum_file`](examples/downloadChecksumFile.zig) — Remote checksum file lookup and verification
- [`download_existing`](examples/downloadExisting.zig) — Existing file policies (fail, overwrite, skip, resume, replace_if_changed)
- [`download_update`](examples/downloadUpdate.zig) — Atomic self-updates with rollback safety
- [`download_info`](examples/downloadInfo.zig) — Metadata HEAD inspection without full body download
- [`download_custom_progress`](examples/downloadCustomProgress.zig) — Custom progress tracking and observers
- [`ftp_download`](examples/ftpDownload.zig) — Direct FTP file download
</details>

<details>
<summary><strong>Parsing & Inspection (DOM Engine) Examples</strong> (Click to expand)</summary>

- [`html_client`](examples/htmlClient.zig) — Client fetch and automatic response.html() parsing
- [`html_select`](examples/htmlSelect.zig) — CSS selector engine queries (tag, .class, #id, [attr], combinators)
- [`html_extract`](examples/htmlExtract.zig) — High-level extraction helpers (title, text, links, forms, images)
- [`html_stream`](examples/htmlStream.zig) — Streaming reader input parsing
- [`html_file`](examples/htmlFile.zig) — HTML file parsing and node inspection
- [`html_transform`](examples/htmlTransform.zig) — Structural mutation, attribute updating, and XSS-safe serialization
- [`parse_html`](examples/parseHtml.zig) — HTML DOM, CSS Selectors, RSS feeds, robots.txt, and sitemaps
</details>

<details>
<summary><strong>File Watching, Static Assets & Live Reload Examples</strong> (Click to expand)</summary>

- [`file_watcher`](examples/fileWatcher.zig) — OS-native file monitoring (Windows ReadDirectoryChangesW, Linux inotify, macOS kqueue) with rename pairing and browser live reload
- [`liveReload`](examples/liveReload.zig) — Live reload dev server with CSS hot reload vs HTML page reload
- [`static_site`](examples/staticSite.zig) — Static site directory mounting with ETag caching and conditional GET
- [`spa_server`](examples/spaServer.zig) — Single Page Application server with client-side route fallback
- [`development_server`](examples/developmentServer.zig) — Unified dev server combining watcher, live reload, and incremental parsing
- [`static/index.html`](examples/static/index.html) — Main HTML page for SPA example
- [`static/about.html`](examples/static/about.html) — About page
- [`static/contact.html`](examples/static/contact.html) — Contact page with form
- [`static/styles.css`](examples/static/styles.css) — CSS styles
- [`static/app.js`](examples/static/app.js) — Client-side JavaScript
</details>

<details>
<summary><strong>Protocols, Security & Network Transport Examples</strong> (Click to expand)</summary>

- [`http2_client`](examples/http2Client.zig) — HTTP/2 client
- [`http2_multiplex`](examples/http2Multiplex.zig) — HTTP/2 stream multiplexing
- [`http2_tls`](examples/http2Tls.zig) — HTTP/2 over TLS with ALPN + chain verification
- [`http3_client`](examples/http3Client.zig) — HTTP/3 client
- [`http3_quic`](examples/http3Quic.zig) — HTTP/3 over QUIC
- [`http3_0rtt`](examples/http3ZeroRtt.zig) — HTTP/3 Zero-RTT connection resumption
- [`tls12_client`](examples/tls12Client.zig) — TLS 1.2 with self-signed cert
- [`tls13_client`](examples/tls13Client.zig) — TLS 1.3 with self-signed cert
- [`tls_mtls`](examples/tlsMtls.zig) — Mutual TLS (mTLS)
- [`resolve`](examples/resolve.zig) — DNS resolution
- [`dns_demo`](examples/dnsDemo.zig) — DNS resolution and IP checks
- [`dns_cache`](examples/dnsCache.zig) — DNS caching
- [`proxy_demo`](examples/proxyDemo.zig) — HTTP forward proxy
- [`connectivity`](examples/connectivity.zig) — Online checks and connectivity probes
- [`compression_demo`](examples/compressionDemo.zig) — gzip/deflate/brotli compression
- [`ftp_client`](examples/ftpClient.zig) — FTP client
- [`tcp_local`](examples/tcpLocal.zig) — Local TCP socket server and client communication
- [`udp_local`](examples/udpLocal.zig) — Local UDP datagram transmission and reception
</details>

<details>
<summary><strong>Templates & Website Examples</strong> (Click to expand)</summary>

- [`web/templates/basic`](examples/web/templates/basic/main.zig) — Basic template rendering
- [`web/templates/inheritance`](examples/web/templates/inheritance/main.zig) — Template inheritance
- [`web/templates/loops`](examples/web/templates/loops/main.zig) — Template loops
- [`web/templates/includes`](examples/web/templates/includes/main.zig) — Template includes
- [`web/templates/liveReload`](examples/web/templates/liveReload/main.zig) — Live-reload templates
- [`web/templates/jinja`](examples/web/templates/jinja/main.zig) — Flask/Jinja2-style templates (extends, blocks, includes, macros, filters)
- [`website`](examples/website/main.zig) — Full website with embedded assets
</details>

<details>
<summary><strong>Advanced Features</strong> (Click to expand)</summary>

- [`multipart`](examples/multipart.zig) — Multipart form data
- [`openapi`](examples/openapi.zig) — OpenAPI spec generation
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
│   ├── httpx.zig                    # Public API entry point and exports
│   ├── client/                      # HTTP client engine
│   │   ├── httpClient.zig           # Client, connection pooling, retries
│   │   ├── requestBuilder.zig       # Request construction and options
│   │   ├── connectionPool.zig       # Connection pool management and stats
│   │   ├── cookieJar.zig            # RFC 6265 client cookie jar
│   │   └── downloadManager.zig      # Downloads, resume, verification, batches
│   ├── server/
│   │   └── httpServer.zig           # Server, routing, TLS, lifecycle
│   ├── web/
│   │   ├── app.zig                  # Unified application facade
│   │   ├── router/                  # Router, context, response, patterns
│   │   ├── middleware/              # CORS, security, rate limiting, auth, CSRF
│   │   ├── rest/                    # REST API framework and OpenAPI reflection
│   │   ├── staticFiles/             # Static files, ETags, MIME detection
│   │   ├── spa/                     # SPA fallback serving
│   │   ├── openApi/                 # OpenAPI 3.1 specification generation
│   │   ├── docs/                    # Swagger UI, ReDoc, Scalar, GraphiQL
│   │   ├── graphql/                 # GraphQL schema, resolvers, mounting
│   │   ├── sse/                     # Server-Sent Events
│   │   ├── websocket/               # WebSocket handshake and frames
│   │   ├── multipart/               # Multipart encoding and parsing
│   │   ├── health/                  # Health-check endpoints
│   │   ├── metrics/                 # Metrics registry and Prometheus output
│   │   ├── auth/                    # Basic and Bearer authentication
│   │   ├── templates/               # Native template engine
│   │   ├── site/                    # File-based website routing
│   │   └── watcher/                 # File watching and browser live reload
│   │       ├── watcherBackend.zig   # Watcher facade, debounce, indexing
│   │       ├── watcherEvents.zig    # Event model and classification
│   │       ├── fileWatcher.zig      # Browser-side live-reload script
│   │       ├── watcherDependency.zig# Dependency graph for invalidation
│   │       ├── windowsWatcher.zig   # Windows directory-change backend
│   │       ├── linuxWatcher.zig     # Linux inotify backend
│   │       └── macosWatcher.zig     # macOS watcher backend
│   ├── protocols/
│   │   ├── http1/                   # HTTP/1.x parsing, writing, semantics
│   │   ├── http2/                   # HTTP/2 frames, HPACK, transport
│   │   ├── http3/                   # HTTP/3 frames, QPACK, transport
│   │   ├── quic/                    # QUIC packets, crypto, frames, connections
│   │   ├── tls/                     # TLS, ALPN, mTLS, certificates
│   │   ├── ftp/                     # FTP client and server
│   │   └── common/                  # Shared protocol utilities
│   ├── net/
│   │   ├── address.zig              # IPv4 and IPv6 address abstraction
│   │   ├── connectivity.zig         # Connectivity probing
│   │   ├── dns/                     # DNS resolution and caching
│   │   │   ├── dnsResolver.zig      # DNS resolution
│   │   │   └── dnsCache.zig         # TTL-aware DNS cache
│   │   ├── proxy.zig                # HTTP proxy support
│   │   ├── resolve.zig              # Host resolution abstraction
│   │   ├── socks4.zig               # SOCKS4/4a tunneling
│   │   └── socks5.zig               # SOCKS5/5h tunneling
│   ├── sockets/
│   │   ├── tcp.zig                  # Cross-platform TCP sockets
│   │   ├── udp.zig                  # UDP socket wrapper
│   │   └── sys.zig                  # System calls and error mapping
│   ├── compression/                 # gzip, Brotli, Zstandard, deflate
│   ├── concurrency/                 # Pools, bounded queues, parallel requests
│   ├── parsing/                     # HTML/XML DOM, CSS selectors, feeds
│   │   ├── html.zig                 # HTML parser
│   │   ├── xml.zig                  # XML parser
│   │   ├── selector.zig             # CSS selector engine
│   │   ├── dom.zig                  # DOM traversal
│   │   ├── document.zig             # Document abstraction
│   │   ├── extract.zig               # Content extraction
│   │   ├── feed.zig                 # RSS, Atom, JSON feeds
│   │   ├── robots.zig               # robots.txt parser
│   │   └── sitemap.zig              # Sitemap parser
│   ├── common/                      # Methods, status, headers, URI, I/O
│   ├── utils/                       # MIME detection and filesystem helpers
│   └── assets/                      # Embedded UI assets
├── examples/                        # Runnable usage examples
├── bench/
│   └── main.zig                     # Benchmarks
├── docs/                            # VitePress documentation
├── build.zig                        # Build configuration
├── build.zig.zon                    # Package metadata
├── README.md
├── SECURITY.md
├── LICENSE
└── CONTRIBUTING.md
```

</details>

## License

MIT License - see [LICENSE](LICENSE) for details.

