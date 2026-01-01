<div align="center">

 
 <img  alt="httpx.zig cover image" src="https://github.com/user-attachments/assets/9ecf8417-4d58-419a-8665-49d5f0eb0573" />


# httpx.zig

<a href="https://muhammad-fiaz.github.io/httpx.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.15.0%2B-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/httpx.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/httpx.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/httpx.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/httpx.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/httpx.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-💖-pink?style=social&logo=github" alt="GitHub Sponsors"></a>


<p><em>A production-ready, high-performance HTTP client and server library for Zig </em></p>

<b>📚 <a href="https://muhammad-fiaz.github.io/httpx.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/api/client">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/httpx.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

> [!WARNING]
> **This project is currently in active development and considered experimental.**  
> APIs are subject to change without notice. Use with caution in production environments.

`httpx.zig` is a comprehensive, high-performance HTTP library designed for building robust networked applications. It features a modern API with support for all major HTTP versions, connection pooling, and express-style server routing.

**⭐️ If you build with `httpx.zig`, make sure to give it a star! ⭐️**

> [!NOTE]
> **Custom HTTP/2 & HTTP/3 Implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support.
> httpx.zig implements these protocols **entirely from scratch**, including:
> - **HPACK** header compression (RFC 7541) for HTTP/2
> - **HTTP/2** stream multiplexing and flow control (RFC 7540)
> - **QPACK** header compression (RFC 9204) for HTTP/3
> - **QUIC** transport framing (RFC 9000) for HTTP/3


---

<details>
<summary><strong>✨ Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| 🌐 **Protocol Support** | Full support for **HTTP/1.0**, **HTTP/1.1**, **HTTP/2** (with HPACK), and **HTTP/3** (with QPACK/QUIC). |
| 📦 **Header Compression** | HPACK (RFC 7541) for HTTP/2 and QPACK (RFC 9204) for HTTP/3. |
| 🔀 **Stream Multiplexing** | HTTP/2 stream state machine with flow control and priority handling. |
| 🔄 **Connection Pooling** | Automatic reuse of TCP connections with keep-alive and health checking. |
| 🛣️ **Express-style Routing** | Intuitive server routing with dynamic path parameters and groups. |
| 📦 **Middleware Stack** | Built-in middleware for CORS, Logging, Rate Limiting, customized Auth, and more. |
| 🚦 **Concurrency** | Parallel request patterns (`race`, `all`, `any`) and async task execution. |
| 🔌 **Interceptors** | Global hooks to modify requests and responses (e.g., Auth injection). |
| 🔁 **Smart Retries** | Configurable retry policies with exponential backoff. |
| 📝 **JSON & HTML** | Helpers for easy JSON serialization and HTML response generation. |
| 🔒 **TLS/SSL** | Secure connections via TLS 1.3 support. |
| 📁 **Static Files** | Efficient static file serving capabilities. |
| 🛡️ **Security** | Security headers (Helmet) and safe defaults. |
| 🚦 **No External Deps** | Pure Zig implementation for maximum portability and ease of build. |

</details>

----

<details>
<summary><strong>📌 Prerequisites & Supported Platforms</strong> (click to expand)</summary>

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
| **Linux** | ✅ | ✅ | ✅ | ✅ |
| **Windows** | ✅ | ✅ | ✅ | ✅ |
| **macOS** | ✅ | ✅ (Apple Silicon) | ✅ | ✅ |
| **FreeBSD** | ✅ | ✅ | ✅ | ✅ |

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

## Quick Start
 
### Installation
 
Add to your `build.zig.zon`:
 
```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/heads/main.tar.gz",
    },
},
```
 
Then in your `build.zig`:
 
```zig
const httpx = b.dependency("httpx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpx", httpx.module("httpx"));
```
 
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
}
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
 
The `examples/` directory contains comprehensive examples for all features:
 
- **Basic**: `simple_get.zig`, `post_json.zig`
- **Advanced Client**: `custom_headers.zig`, `connection_pool.zig`, `interceptors.zig`
- **Concurrency**: `concurrent_requests.zig` (Parallel/Race/All patterns)
- **Server**: `simple_server.zig`, `router_example.zig`, `static_files.zig`
- **Middleware**: `middleware_example.zig`
- **Streaming**: `streaming.zig`
 
To run an example:
```bash
zig build run-simple_get
```
 
## Performance
 
Run benchmarks:
 
```bash
zig build bench
```
> Note: Benchmark results will vary based on hardware and network conditions.
 
## Contributing
 
Contributions are welcome! Please:
 
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request
 
## License
 
MIT License - see [LICENSE](LICENSE) for details.
