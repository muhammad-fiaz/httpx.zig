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


`httpx.zig` is a comprehensive, high-performance HTTP library for building robust networked applications in Zig, with modern client and server primitives, support for major HTTP versions, connection pooling, and pattern-based routing. You can build your own APIs and website servers directly on top of these components; see the runnable examples in the repository: [examples/](https://github.com/muhammad-fiaz/httpx.zig/tree/main/examples), [examples/static_files.zig](https://github.com/muhammad-fiaz/httpx.zig/blob/main/examples/static_files.zig), and [examples/multi_page_website.zig](https://github.com/muhammad-fiaz/httpx.zig/blob/main/examples/multi_page_website.zig).

**Related Zig projects:**

- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.

⭐ If you build with httpx.zig, make sure to give it a star. ⭐


> [!WARNING]
> `v0.1.0` is a major update from `0.0.7`.
> It introduces built-in auth/content helpers, expanded top-level aliases, runtime/API refinements, and broader utility/docs coverage.
> If you are migrating from `0.0.7`, review the changelog and refresh your install pin/hash before upgrading.


> [!NOTE]
> **Project maturity:** This project aims to be production-ready and is actively maintained. It is still a new project and not yet widely adopted. Feel free to use it in your projects.
>
> **Custom HTTP/2 & HTTP/3 implementation:** Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support.
> httpx.zig implements these protocols **entirely from scratch**, including:
> - **HPACK** header compression (RFC 7541) for HTTP/2
> - **HTTP/2 high-level client and server runtime paths** (preface/settings/headers/data flow)
> - **HTTP/2** stream multiplexing and flow control (RFC 7540)
> - **QPACK** header compression (RFC 9204) for HTTP/3
> - **QUIC** transport framing (RFC 9000) for HTTP/3
> - **HTTP/3 high-level client and server runtime paths** over UDP + QUIC/HTTP3/QPACK primitives
> - **Interop note:** strict TLS-in-QUIC server negotiation expectations may vary by endpoint deployment

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description | Documentation |
|---------|-------------|---------------|
| **Protocol Support** | Full runtime support for **HTTP/1.0**, **HTTP/1.1**, **HTTP/2**, and **HTTP/3** in high-level client/server APIs, plus low-level protocol primitives. | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Header Compression** | HPACK (RFC 7541) for HTTP/2 and QPACK (RFC 9204) for HTTP/3. | https://muhammad-fiaz.github.io/httpx.zig/guide/http2 |
| **Stream Multiplexing** | HTTP/2 stream state machine with flow control and priority handling. | https://muhammad-fiaz.github.io/httpx.zig/api/protocol |
| **Connection Pooling** | Automatic reuse of TCP connections with keep-alive and health checking. | https://muhammad-fiaz.github.io/httpx.zig/guide/pooling |
| **Pool Introspection** | Built-in connection pool stats and per-host connection counts. | https://muhammad-fiaz.github.io/httpx.zig/api/pool |
| **Pattern-based Routing** | Intuitive server routing with dynamic path parameters and groups. | https://muhammad-fiaz.github.io/httpx.zig/guide/routing |
| **Port Conflict Handling** | Explicit startup strategy to fail fast or auto-increment to the next free port. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Middleware Stack** | Built-in middleware for CORS, Logging, Rate Limiting, customized Auth, and more. | https://muhammad-fiaz.github.io/httpx.zig/guide/middleware |
| **Pre-Route and Global Handlers** | `preRoute(...)` hooks and `global(...)` fallback handlers for complete request lifecycle control. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Unified Any-Method Routing** | `any(path, handler)` to register all standard HTTP methods on one endpoint. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Concurrency** | Parallel request patterns (`race`, `all`, `any`) and async task execution. | https://muhammad-fiaz.github.io/httpx.zig/guide/concurrency |
| **Interceptors** | Global hooks to modify requests and responses (e.g., Auth injection). | https://muhammad-fiaz.github.io/httpx.zig/guide/interceptors |
| **Smart Retries** | Configurable retry policies with exponential backoff. | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **Config Builder Helpers** | Chainable optional customization helpers for `ClientConfig` and `RequestOptions` (defaults remain implicit). | https://muhammad-fiaz.github.io/httpx.zig/api/client |
| **JSON and HTML** | Helpers for easy JSON serialization and HTML response generation. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **Core Convenience APIs** | Request query-param helpers and response constructors for redirect/text/json. | https://muhammad-fiaz.github.io/httpx.zig/api/core |
| **TLS/SSL** | Secure connections via TLS 1.3 support. | https://muhammad-fiaz.github.io/httpx.zig/api/tls |
| **Static Files** | Efficient static file serving capabilities. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Streaming and Realtime** | Chunked transfer responses with optional trailers and SSE response helpers. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Cookie APIs** | First-class request/response cookie helpers for both client and server contexts. | https://muhammad-fiaz.github.io/httpx.zig/api/server |
| **Security** | Security headers (Helmet) and safe defaults. | https://muhammad-fiaz.github.io/httpx.zig/api/middleware |
| **No External Dependencies** | Pure Zig implementation for maximum portability and ease of build. | https://muhammad-fiaz.github.io/httpx.zig/guide/installation |
| **Shared Common Helpers** | Reusable query/cookie helpers plus MIME resolution with explicit fallback and external mapping support. | https://muhammad-fiaz.github.io/httpx.zig/api/utils |

</details>

----

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `httpx.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | 0.16.0+ | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform networking support |

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

### Method 1: Zig Fetch (Latest Release 0.1.0)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.0.tar.gz
```

### Method 2: Zig Fetch (Previous Stable 0.0.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.7.tar.gz
```

### Method 3: Zig Fetch (Nightly/Main)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

### Method 4: Manual `build.zig.zon` Configuration

Add this dependency entry to your `build.zig.zon`:

```zig
.dependencies = .{
    .httpx = .{
        .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.0.tar.gz",
        .hash = "...", // Run zig fetch --save <url> to auto-fill this.
    },
},
```

### Method 5: Local Source Checkout

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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
 
    // Create client with implicit defaults.
    // Use explicit ClientConfig overrides only when you need to change defaults.
    var client = httpx.Client.initForBaseUrl(allocator, "https://httpbin.org");
    defer client.deinit();
 
    // Simple GET request (request defaults are implicit)
    var response = try client.get("/get", .{});
    defer response.deinit();
 
    if (response.ok()) {
        std.debug.print("Response: {s}\n", .{response.text() orelse ""});
    }
 
    // POST with JSON
    var post_response = try client.post(
        "/post",
        .{ .json = "{\"name\": \"John\"}" },
    );
    defer post_response.deinit();

    // Cookie jar helpers
    try client.setCookie("session", "abc123");
    _ = client.getCookie("session");

    // Pool stats/maintenance helpers (optional)
    client.cleanupIdleConnections();
    const pool_stats = client.poolStats();
    _ = pool_stats;
}
```

### Simplified API Aliases

```zig
// Top-level aliases for concise client code.
// Allocator is implicit by default.
var response = try httpx.fetch("https://httpbin.org/get");
defer response.deinit();

// Defaults are implicit; pass .{} for default request options.
var by_method = try httpx.send(.GET, "https://httpbin.org/headers", .{});
defer by_method.deinit();

// Additional aliases
var del_res = try httpx.delete("https://httpbin.org/delete", .{});
defer del_res.deinit();

var opts_res = try httpx.opts("https://httpbin.org/get", .{});
defer opts_res.deinit();

// Optional explicit override (only when needed)
var timed = try httpx.sendWithAllocator(allocator, .GET, "https://httpbin.org/headers", .{ .timeout_ms = 10_000 });
defer timed.deinit();
```

### Explicit Network Helpers

```zig
// Network lifecycle (optional explicit init/deinit)
try httpx.netInit();
defer httpx.netDeinit();

// Address helpers
const one = try httpx.resolveAddress("example.com", 443);
_ = one;

const parsed = try httpx.parseHostAndPort("localhost:8080", 80);
_ = parsed;

const final_addr = try httpx.parseAndResolveAddress("127.0.0.1:9000", 80);
_ = final_addr;

const is_ip = httpx.isIpAddress("::1");
_ = is_ip;
```

### Explicit Concurrency Helpers

```zig
const specs = [_]httpx.RequestSpec{
    .{ .method = .GET, .url = "https://httpbin.org/get", .timeout_ms = 5_000 },
    .{ .method = .GET, .url = "https://httpbin.org/headers", .version = .HTTP_2 },
};

var client_for_concurrency = httpx.Client.init(allocator);
defer client_for_concurrency.deinit();

var all_results = try httpx.all(allocator, &client_for_concurrency, &specs);
defer {
    for (all_results) |*r| r.deinit();
    allocator.free(all_results);
}

const ok_count = httpx.successfulCount(all_results);
const err_count = httpx.errorCount(all_results);
_ = ok_count;
_ = err_count;

var first_ok = try httpx.first(allocator, &client_for_concurrency, &specs);
if (first_ok) |*resp| resp.deinit();
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
 
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_conflict = .increment,
        .max_port_tries = 32,
    });
    defer server.deinit();
 
    // Add middleware
    try server.use(httpx.logger());
    try server.use(httpx.cors(.{}));
 
    // Register routes
    try server.get("/", helloHandler);
    try server.get("/page", htmlHandler);
 
    // Start server
    try server.listen();

    // Effective port after startup (useful when port_conflict = .increment)
    std.debug.print("Listening on {d}\n", .{server.listeningPort()});
}
```

### Server Port Conflict Handling

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
    .port_conflict = .increment, // try 8081, 8082, ... when 8080 is occupied
    .max_port_tries = 32,
});
defer server.deinit();

try server.listen();
```

- `port_conflict = .fail`: fail immediately if the configured port cannot be bound.
- `port_conflict = .increment`: retry subsequent ports until success or `max_port_tries` is exhausted.
- `server.listeningPort()`: returns the effective bound port.
 
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
- **Protocol Demos**: `http2_example.zig`, `http2_client_runtime.zig`, `http2_server_runtime.zig`, `http3_example.zig`, `http3_client_runtime.zig`, `http3_server_runtime.zig`
- **Networking Utility**: `tcp_local.zig`, `udp_local.zig`
 
To run an example:
```bash
zig build run-simple_get
```

## Validation Matrix

Validate host functionality and cross-target compatibility with these commands:

```bash
# Host runtime validation
zig build test
zig build run-all-examples

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

Latest benchmark snapshot (`x86_64-windows`, `ReleaseFast`):

| Benchmark | Avg (ns/op) | Throughput (ops/sec) |
|-----------|-------------|----------------------|
| headers_parse | 34228.26 | 29215 |
| uri_parse | 53.14 | 18818251 |
| status_lookup | 2.28 | 439313265 |
| method_lookup | 9.27 | 107889064 |
| base64_encode | 4569.04 | 218864 |
| base64_decode | 4859.87 | 205766 |
| json_builder | 4687.50 | 213333 |
| request_build | 26806.72 | 37304 |
| response_builders | 35379.08 | 28265 |
| h2_frame_header | 1.82 | 550533466 |
| h3_varint_encode | 1.22 | 816790601 |
 
## Contributing
 
Contributions are welcome! Please:
 
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request
 
## License
 
MIT License - see [LICENSE](LICENSE) for details.
