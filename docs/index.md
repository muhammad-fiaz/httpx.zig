---
layout: home

hero:
  name: httpx.zig
  text: Production-Ready HTTP Library for Zig
  tagline: Full HTTP/1.1, HTTP/2 with HPACK, HTTP/3 with QPACK/QUIC support
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
    details: Full HTTP/1.1 client/server, HTTP/2 with HPACK compression and streams, HTTP/3 with QPACK and QUIC framing.
  - title: Robust Client
    details: Connection pooling, automatic retries, interceptors, and typed API.
  - title: Powerful Server
    details: Pattern-based routing, middleware support, and context-based handling.
  - title: Concurrent
    details: Async task executor and parallel request patterns (all, any, race).
  - title: TLS Security
    details: Secure connections with TLS 1.2/1.3, custom CAs, and verification policies.
  - title: Low-level Control
    details: Direct access to sockets, buffers, protocol parsers, and HPACK/QPACK compression.
---

## Install

Choose one of these installation methods:

1. Stable release (recommended)

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz
```

2. Nightly/main branch

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig
```

3. Manual dependency entry in `build.zig.zon`

```zig
.dependencies = .{
  .httpx = .{
    .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz",
    .hash = "...",
  },
},
```

::: tip Release maturity
httpx.zig is built with production-readiness as a core goal. It is still a relatively new project, so adoption is growing. You can use it in real projects while tracking changelogs between releases.
:::

## Related Zig Projects

- For API framework support, check out [api.zig](https://github.com/muhammad-fiaz/api.zig).
- For web framework support, check out [zix](https://github.com/muhammad-fiaz/zix).

For full setup details, including local path dependencies and `build.zig` wiring, see `/guide/installation`.

::: warning Custom HTTP/2 & HTTP/3 Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols entirely from scratch**, including:
- **HPACK** header compression (RFC 7541) for HTTP/2
- **HTTP/2** stream multiplexing and flow control (RFC 7540)
- **QPACK** header compression (RFC 9204) for HTTP/3
- **QUIC** transport framing (RFC 9000) for HTTP/3
:::

## Protocol Support

| Protocol | Status | Features |
|----------|--------|----------|
| HTTP/1.0 | ✅ Full | Basic request/response |
| HTTP/1.1 | ✅ Full | Keep-alive, chunked transfer, pipelining |
| HTTP/2 | ✅ Full | HPACK compression, stream multiplexing, flow control |
| HTTP/3 | ✅ Full | QPACK compression, QUIC transport framing |

## Platform Support

httpx.zig is fully cross-platform:

| Platform | x86_64 | aarch64 | i386 | arm |
|----------|--------|---------|------|-----|
| Linux    | ✅     | ✅      | ✅   | ✅  |
| Windows  | ✅     | ✅      | ✅   | ✅  |
| macOS    | ✅     | ✅      | ✅   | ✅  |
| FreeBSD  | ✅     | ✅      | ✅   | ✅  |

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
- `http3_example.zig`: HTTP/3 QPACK compression and QUIC framing
- `udp_local.zig`: UDP local networking utility

## Configuration

Client configuration lives on `ClientConfig` (timeouts, redirects, retries, TLS verification, keep-alive/pooling).
