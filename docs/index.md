---
layout: home

hero:
  name: httpx.zig
  text: Production-Ready HTTP Library for Zig
  tagline: Production-ready HTTP/1.x/2/3 client and server runtime, plus protocol primitives
  image:
    src: /logo.png
    alt: httpx.zig
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /api/client
    - theme: alt
      text: View on GitHub
      link: https://github.com/muhammad-fiaz/httpx.zig

features:
  - title: All HTTP Versions
    details: Full HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 client/server runtime support, plus full protocol primitives.
  - title: Robust Client
    details: Connection pooling, automatic retries, interceptors, typed API, and default-safe chainable config/option overrides.
  - title: Powerful Server
    details: Pattern-based routing, middleware support, context-based handling, ETag-aware static file helpers, and explicit port conflict startup strategies.
  - title: Concurrent
    details: Async task executor and parallel request patterns (all, any, race).
  - title: TLS Security
    details: Secure connections with TLS 1.2/1.3, custom CAs, and verification policies.
  - title: Low-level Control
    details: Direct access to sockets, buffers, protocol parsers, and HPACK/QPACK compression.
  - title: MIME Ready
    details: Case-insensitive MIME detection for common web/document/media/font/archive formats with explicit fallback override.
---

## Install

::: warning v0.1.1 release and Zig 0.15 deprecation
`v0.1.1` is the current release and targets Zig `0.16.0+`.
`v0.1.0` is the previous stable release for the immediate prior `0.1.x` line.
Zig `0.15` support is legacy and remains available only through `0.0.7`.
The HTTPS/TLS reader fix for Zig `0.16` empty-buffer reads is included in this release.
If you are upgrading from `0.0.7`, review `/CHANGELOG` first and refresh your dependency pin/hash.
:::

Choose one of these installation methods:

1. Latest release (0.1.1)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.1.tar.gz
```

2. Previous stable release (0.1.0)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.0.tar.gz
```

3. Legacy Zig 0.15 support (0.0.7)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.7.tar.gz
```

::: warning Zig 0.15 deprecation
Zig `0.15` is deprecated. It uses an older API surface and is only retained in `0.0.7`.
:::

4. Nightly/main branch

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig
```

5. Manual dependency entry in `build.zig.zon`

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.1.tar.gz",
    .hash = "...",
  },
},
```

::: tip Release maturity
httpx.zig is built with production-readiness as a core goal. It is still a relatively new project, so adoption is growing. You can use it in real projects while tracking changelogs between releases.
:::

::: tip Related Zig Projects
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
:::

For full setup details, including local path dependencies and `build.zig` wiring, see `/guide/installation`.

::: warning Custom HTTP/2 & HTTP/3 Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols entirely from scratch**, including:
- **HPACK** header compression (RFC 7541) for HTTP/2
- **HTTP/2** stream multiplexing and flow control (RFC 7540)
- **QPACK** header compression (RFC 9204) for HTTP/3
- **QUIC** transport framing (RFC 9000) for HTTP/3
:::

## Protocol Support

| Protocol | Status | Transport | Notes |
|----------|--------|-----------|-------|
| HTTP/1.0 | ✅ Full | TCP | Legacy support |
| HTTP/1.1 | ✅ Full | TCP/TLS | Default protocol |
| HTTP/2 | ✅ Client + Server Runtime + Primitives | TCP/TLS | High-level client/server execution paths plus full framing/HPACK/stream primitives |
| HTTP/3 | ✅ Client + Server Runtime + Primitives | QUIC/UDP | High-level client/server runtime over UDP + QUIC/HTTP3/QPACK primitives |

## Platform Support

httpx.zig is validated across Linux, Windows, and macOS:

| Platform | x86_64 | aarch64 | x86 |
|----------|--------|---------|-----|
| Linux    | ✅     | ✅      | ✅  |
| Windows  | ✅     | ✅      | ✅  |
| macOS    | ✅     | ✅      | ❌  |

## Examples

All examples are runnable from the repo root:

```bash
zig build run-simple_get
```

Available examples (see the `/examples` folder):

- `simple_get.zig`: minimal GET
- `simple_get_deserialize.zig`: GET request with typed JSON deserialization
- `post_json.zig`: JSON POST
- `custom_headers.zig`: request headers
- `interceptors.zig`: request/response interception hooks
- `middleware_example.zig`: middleware chain
- `router_example.zig`: router + handlers
- `simple_server.zig`: basic HTTP server
- `streaming.zig`: streaming request/response bodies
- `concurrent_requests.zig`: concurrency patterns
- `connection_pool.zig`: keep-alive pooling
- `cookies_demo.zig`: cookie jar management
- `simplified_api_aliases.zig`: simplified top-level/client aliases
- `static_files.zig`: file-based static routes and directory-based wildcard mounts for CSS/JS/images
- `multi_page_website.zig`: full multi-page website serving index/about/contact with static assets
- `http2_example.zig`: HTTP/2 HPACK compression and stream management
- `http2_client_runtime.zig`: local end-to-end high-level HTTP/2 client runtime demo
- `http2_server_runtime.zig`: local end-to-end high-level HTTP/2 server runtime demo
- `http3_example.zig`: HTTP/3 QPACK compression and QUIC framing
- `http3_client_runtime.zig`: local end-to-end high-level HTTP/3 client runtime demo
- `http3_server_runtime.zig`: local end-to-end high-level HTTP/3 server runtime demo
- `tcp_local.zig`: local TCP listener/client round trip
- `udp_local.zig`: UDP local networking utility

## Configuration

Client configuration lives on `ClientConfig` (timeouts, redirects, retries, TLS verification, keep-alive/pooling).

For a full explicit export map (root aliases + API groups), see [API Overview](/api/).

## Validation

Use these commands to validate host runtime behavior and cross-target compatibility:

```bash
zig build test
zig build run-all-examples
zig build build-all-targets
```

To validate Linux runtime behavior (not just compile checks), build Linux artifacts and run them from Linux/WSL:

```bash
zig build test -Dtarget=x86_64-linux
zig build example-tcp_local -Dtarget=x86_64-linux

./zig-out/bin/test
./zig-out/bin/tcp_local
```

For production client code, prefer explicit timeout + error handling so failures surface immediately:

```zig
var response = client.get(url, .{ .timeout_ms = 10_000 }) catch |err| {
  std.debug.print("request failed: {s}\n", .{@errorName(err)});
  return;
};
defer response.deinit();
```

For detailed target-matrix instructions, see [Installation](/guide/installation#validation-and-target-matrix).
