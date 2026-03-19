<div align="center">
<img src="https://github.com/user-attachments/assets/ae3e1cc2-41f8-4326-b757-c9afcf6c8fea" alt="httpx.zig logo" width="400" />

<a href="https://muhammad-fiaz.github.io/httpx.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.15.2-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/httpx.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/httpx.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/httpx.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/httpx.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/httpx.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/github-code-scanning/codeql"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/github-code-scanning/codeql/badge.svg" alt="CodeQL"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/release.yml"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/release.yml/badge.svg" alt="Release"></a>
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

> [!NOTE]
> **This project aims to be production-ready and is actively maintained.**  
> It is still a new project and not yet widely adopted. Feel free to use it in your projects.

`httpx.zig` is a comprehensive, high-performance HTTP library for building robust networked applications in Zig, with modern client and server primitives, support for major HTTP versions, connection pooling, and pattern-based routing. You can build your own APIs and website servers directly on top of these components; see the runnable examples in the repository: [examples/](https://github.com/muhammad-fiaz/httpx.zig/tree/main/examples), [examples/static_files.zig](https://github.com/muhammad-fiaz/httpx.zig/blob/main/examples/static_files.zig), and [examples/multi_page_website.zig](https://github.com/muhammad-fiaz/httpx.zig/blob/main/examples/multi_page_website.zig).

Related Zig projects:

- For API framework support, check out [api.zig](https://github.com/muhammad-fiaz/api.zig).
- For web framework support, check out [zix](https://github.com/muhammad-fiaz/zix).

⭐ If you build with httpx.zig, make sure to give it a star. ⭐

> [!NOTE]
> **Custom HTTP/2 & HTTP/3 Implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support.
> httpx.zig implements these protocols **entirely from scratch**, including:
> - **HPACK** header compression (RFC 7541) for HTTP/2
> - **HTTP/2** stream multiplexing and flow control (RFC 7540)
> - **QPACK** header compression (RFC 9204) for HTTP/3
> - **QUIC** transport framing (RFC 9000) for HTTP/3


---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description | Documentation |
|---------|-------------|---------------|
| **Protocol Support** | Full support for **HTTP/1.0**, **HTTP/1.1**, **HTTP/2** (with HPACK), and **HTTP/3** (with QPACK/QUIC). | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Header Compression** | HPACK (RFC 7541) for HTTP/2 and QPACK (RFC 9204) for HTTP/3. | https://muhammad-fiaz.github.io/httpx.zig/guide/http2 |
| **Stream Multiplexing** | HTTP/2 stream state machine with flow control and priority handling. | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Connection Pooling** | Automatic reuse of TCP connections with keep-alive and health checking. | https://muhammad-fiaz.github.io/httpx.zig/guide/pooling |
| **Pool Introspection** | Built-in connection pool stats and per-host connection counts. | https://muhammad-fiaz.github.io/httpx.zig/api/pool |
| **Pattern-based Routing** | Intuitive server routing with dynamic path parameters and groups. | https://muhammad-fiaz.github.io/httpx.zig/guide/routing |
| **Middleware Stack** | Built-in middleware for CORS, Logging, Rate Limiting, customized Auth, and more. | https://muhammad-fiaz.github.io/httpx.zig/guide/middleware |
| **Concurrency** | Parallel request patterns (`race`, `all`, `any`) and async task execution. | https://muhammad-fiaz.github.io/httpx.zig/guide/concurrency |
| **Interceptors** | Global hooks to modify requests and responses (e.g., Auth injection). | https://muhammad-fiaz.github.io/httpx.zig/guide/interceptors |
| **Smart Retries** | Configurable retry policies with exponential backoff. | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **JSON and HTML** | Helpers for easy JSON serialization and HTML response generation. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **Core Convenience APIs** | Request query-param helpers and response constructors for redirect/text/json. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **TLS/SSL** | Secure connections via TLS 1.3 support. | https://muhammad-fiaz.github.io/httpx.zig/api/tls |
| **Static Files** | Efficient static file serving capabilities. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Security** | Security headers (Helmet) and safe defaults. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **No External Dependencies** | Pure Zig implementation for maximum portability and ease of build. | https://muhammad-fiaz.github.io/httpx.zig/guide/installation |
| **Shared Common Helpers** | Reusable query and cookie parsing helpers for app and library code. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |

</details>

----

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `httpx.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | 0.15.0+ | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS, FreeBSD | Cross-platform networking support |

---

## Supported Platforms

`httpx.zig` compiles and runs on a wide range of architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | i386 (32-bit) | arm (32-bit) |
|----------|-----------------|-----------------|---------------|--------------|
| **Linux** | Yes | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | Yes | Yes |
| **FreeBSD** | Yes | Yes | Yes | Yes |

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
zig build -Dtarget=i386-windows
```

</details>

---

## Installation

### Method 1: Zig Fetch (Recommended Stable Release)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz
```

### Method 2: Zig Fetch (Nightly/Main)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

Add this dependency entry to your `build.zig.zon`:

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz",
        .hash = "...", // Run zig fetch --save <url> to auto-fill this.
    },
},
```

### Method 4: Local Source Checkout

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

If you want to consume a local checkout from another project, use a local path dependency:

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

### Client Usage
 
```zig
const std = @import("std");
const httpx = @import("httpx");
 
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
 
    // Create client
    var client = httpx.Client.init(allocator);
    defer client.deinit();
 
    // Simple GET request
    var response = try client.get("https://httpbin.org/get", .{});
    defer response.deinit();
 
    if (response.ok()) {
        std.debug.print("Response: {s}\n", .{response.text() orelse ""});
    }
 
    // POST with JSON
    var post_response = try client.post("https://httpbin.org/post", .{
        .json = "{\"name\": \"John\"}",
    });
    defer post_response.deinit();

    // Cookie jar helpers
    try client.setCookie("session", "abc123");
    _ = client.getCookie("session");
}
```

### Simplified API Aliases

```zig
// Top-level aliases for concise client code.
// Reuses the same allocator declared above.
var response = try httpx.fetch(allocator, "https://httpbin.org/get");
defer response.deinit();

var by_method = try httpx.send(allocator, .GET, "https://httpbin.org/headers", .{});
defer by_method.deinit();
```
 
### Server Usage
 
```zig
const std = @import("std");
const httpx = @import("httpx");
 
fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .message = "Hello, World!" });
}
 
fn htmlHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html("<h1>Hello from httpx.zig!</h1>");
}
 
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
 
    var server = httpx.Server.init(allocator);
    defer server.deinit();
 
    // Add middleware
    try server.use(httpx.logger());
    try server.use(httpx.cors(.{}));
 
    // Register routes
    try server.get("/", helloHandler);
    try server.get("/page", htmlHandler);
 
    // Start server
    try server.listen();
}
```
 
## Examples
 
The `examples/` directory contains comprehensive examples for all major features:
 
- **Basic Client**: `simple_get.zig`, `post_json.zig`
- **JSON Parse**: `simple_get_deserialize.zig` (GET + typed JSON deserialization)
- **Advanced Client**: `custom_headers.zig`, `connection_pool.zig`, `interceptors.zig`
- **Cookies**: `cookies_demo.zig`
- **Simplified API**: `simplified_api_aliases.zig`
- **Concurrency**: `concurrent_requests.zig` (Parallel/Race/All patterns)
- **Streaming**: `streaming.zig`
- **Server Core**: `simple_server.zig`, `router_example.zig`, `middleware_example.zig`
- **Static Assets Demo**: `static_files.zig` (file-based static routes + directory-based wildcard mounts for CSS/JS/images)
- **Website Demo**: `multi_page_website.zig` (full multi-page website serving `index/about/contact` with static assets)
- **Protocol Demos**: `http2_example.zig`, `http3_example.zig`
- **Networking Utility**: `udp_local.zig`
 
To run an example:
```bash
zig build run-simple_get
```
 
## Performance
 
Run benchmarks:
 
```bash
zig build bench
```
> [!NOTE]
> Benchmark results will vary based on hardware and network conditions.
> The benchmark suite reports multiple rounds with min/avg/max and throughput to improve result quality.

Latest benchmark snapshot (`x86_64-windows`, `ReleaseFast`):

| Benchmark | Avg (ns/op) | Throughput (ops/sec) |
|-----------|-------------|----------------------|
| headers_parse | 44755.50 | 22343 |
| uri_parse | 93.72 | 10669580 |
| status_lookup | 2.05 | 487291439 |
| method_lookup | 13.97 | 71576530 |
| base64_encode | 13861.42 | 72142 |
| base64_decode | 13912.25 | 71879 |
| json_builder | 14178.73 | 70528 |
| request_build | 35754.42 | 27968 |
| response_builders | 51674.39 | 19351 |
| h2_frame_header | 2.08 | 481398752 |
| h3_varint_encode | 2.47 | 404809787 |
 
## Contributing
 
Contributions are welcome! Please:
 
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request
 
## License
 
MIT License - see [LICENSE](LICENSE) for details.
