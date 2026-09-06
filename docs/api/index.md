# API Overview

This page maps the explicit public API surface exposed by `httpx.zig`.

## Root Module (`httpx`)

The root module re-exports core types and convenience helpers so most apps can import only `httpx`.

### Client Helpers

- `httpx.fetch(url)` — alias for GET
- `httpx.send(method, url, options)` — explicit method
- `httpx.get/post/put/delete/del/patch/head/trace/connect/options/opts(...)`
- `httpx.getJson(T, url, parse_opts)` — GET + parse JSON
- `httpx.postJson(url, body)` — POST raw JSON
- `httpx.postJsonAndParse(T, url, body, parse_opts)` — POST + parse JSON
- `httpx.putJson/patchJson/deleteJson(T, url, body, parse_opts)` — other methods + parse
- `httpx.getJsonBorrowed/postJsonBorrowed(T, url, body)` — zero-copy borrowed parsing
- Explicit allocator overrides: `httpx.*WithAllocator(...)` for every alias above.

### Client Shorthand

- `httpx.createClient()` — page_allocator shorthand
- `httpx.createClientWithConfig(allocator, config)` — explicit allocator + config

### Server Shorthand

- `httpx.createServer()` — page_allocator shorthand
- `httpx.createServerWithConfig(allocator, config)` — explicit allocator + config
- `httpx.serve(path, handler)` — one-shot create + register GET + listen
- `httpx.serveWithConfig(allocator, config, path, handler)` — same with config

### Optional Client Builder Helpers

- `httpx.ClientConfig.defaults().withDefaultHeaders(...)`
- `httpx.ClientConfig.defaults().withFollowRedirects(...)`
- `httpx.ClientConfig.defaults().withHttp2Settings(...)`
- `httpx.ClientConfig.defaults().withHttp3Settings(...)`
- `httpx.ClientConfig.defaults().withSslVerification(...)`
- `httpx.ClientConfig.defaults().withKeepAlive(...)`
- `httpx.ClientConfig.defaults().withMaxResponseSize(...)`
- `httpx.ClientConfig.defaults().withProxy(...)`
- `httpx.ClientConfig.defaults().withRetryPolicy(...)`
- `httpx.ClientConfig.defaults().withTimeouts(...)`
- `httpx.ClientConfig.defaults().withLogFn(...)`
- `httpx.ClientConfig.defaults().withPoolLimits(...)`
- `httpx.RequestOptions.defaults().withQueryParams(...)`
- `httpx.RequestOptions.defaults().withFormUrlEncoded(...)`
- `httpx.RequestOptions.defaults().withBearerToken(...)`
- `httpx.RequestOptions.defaults().withBasicAuth(...)`
- `httpx.RequestOptions.defaults().withVersion(...)`
- `httpx.RequestOptions.defaults().withHttp2()`
- `httpx.RequestOptions.defaults().withHttp3()`
- `httpx.RequestOptions.defaults().withJson(...)`
- `httpx.RequestOptions.defaults().withHeaders(...)`
- `httpx.RequestOptions.defaults().withFollowRedirects(...)`
- `httpx.RequestOptions.defaults().withTimeout(...)`
- `httpx.RequestOptions.defaults().withMultipartFields(...)`
- `httpx.RequestOptions.defaults().withMultipartFiles(...)`
- `httpx.RequestOptions.defaults().withMultipartBoundary(...)`
- `httpx.BasicAuth`
- `httpx.Proxy`
- `httpx.ProxyKind`

### Server Types

- `httpx.Server`
- `httpx.ServerConfig`
- `httpx.PortConflictStrategy`
- `httpx.FileResponseOptions`

### Concurrency Helpers

- `httpx.all(...)`
- `httpx.any(...)`
- `httpx.race(...)`
- `httpx.allSettled(...)`
- `httpx.first(...)` (alias for `any`)
- `httpx.fastest(...)` (alias for `race`)
- `httpx.settled(...)` (alias for `allSettled`)
- `httpx.successfulCount(...)`
- `httpx.errorCount(...)`
- `httpx.BatchBuilder`

### Network Helpers

- `httpx.netInit()` / `httpx.netDeinit()`
- `httpx.resolveAddress(allocator, host, port)`
- `httpx.resolveAllAddresses(allocator, host, port)`
- `httpx.parseHostAndPort(input, default_port)`
- `httpx.parseAndResolveAddress(input, default_port)`
- `httpx.isIpAddress/isIp4Address/isIp6Address(...)`

### Utility Aliases

- `httpx.queryValue(...)`
- `httpx.parseSetCookiePair(...)`
- `httpx.mimeTypeFromPath(...)`
- `httpx.mimeTypeFromPathOr(...)`
- `httpx.mimeTypeFromPathWith(...)`
- `httpx.MimeMapping`
- `httpx.defaultMimeMappings`
- `httpx.encodeVarInt(...)`
- `httpx.decodeVarInt(...)`
- `httpx.sleepMs(ms)`
- `httpx.defaultIo()`

### Caching

- `httpx.CacheControl` — parse Cache-Control headers
- `httpx.HttpCache` — LRU in-memory cache with TTL
- `httpx.CacheEntry` — individual cache entry
- `httpx.ConditionalGet` — ETag/If-None-Match conditional requests

### Streaming Compression

- `httpx.StreamingCompressor` — chunked gzip/deflate/brotli/zstd compression
- `httpx.StreamingDecompressor` — chunked decompression
- `httpx.ContentEncoding` — encoding enum
- `httpx.decompress(...)` / `httpx.compress(...)` — one-shot compression

### Buffer Pool

- `httpx.BufferPool` — pre-allocated buffer pool with ownership tracking

### DNS Cache

- `httpx.dns.DnsCache` — thread-safe DNS cache with TTL and eviction

### WebSocket

- `httpx.isWebSocketUpgrade(...)`, `httpx.wsExtractKey(...)`, `httpx.wsAcceptKey(...)`
- `httpx.wsUpgradeHeaders(...)` — generate upgrade response headers
- `httpx.wsEncodeFrame(...)` / `httpx.wsDecodeFrame(...)` — frame encode/decode
- `httpx.wsTextFrame(...)`, `wsBinaryFrame(...)`, `wsPingFrame(...)`, `wsPongFrame(...)`, `wsCloseFrame(...)`

### Debug

- `httpx.debug` — structured debug logging with `entry`/`exit`/`log`/`detail` calls

## API Groups

- [Client API](/api/client)
- [Concurrency API](/api/concurrency)
- [Core API](/api/core)
- [DNS API](/api/dns)
- [Middleware API](/api/middleware)
- [Network API](/api/net)
- [Pool API](/api/pool)
- [Protocol API](/api/protocol)
- [Router API](/api/router)
- [Server API](/api/server)
- [TLS API](/api/tls)
- [Utilities API](/api/utils)

## Explicit Support Notes

- HTTP/1.0 and HTTP/1.1 are production runtime paths in the high-level client/server API.
- HTTP/2 has high-level client and server runtime paths plus full protocol primitives (HPACK/framing/streams).
- HTTP/3 has high-level client and server runtime paths over UDP/QUIC stream framing, plus full protocol primitives (QPACK/HTTP3/QUIC framing).
- Cross-platform validation is maintained for Linux/Windows (x86, x86_64, aarch64) and macOS (x86_64, aarch64) build matrices.

## Customization and Callbacks

- Client interceptors for request/response hooks: `addInterceptor(...)`
- Server logging sinks via `ServerConfig.log_fn`
- Middleware logger customization via `loggerWithConfig(.{ .log_fn = ... })`
- Request and response JSON helpers: `RequestOptions.withJson(...)`, `Response.json(T, options)`, `Response.jsonLeaky(T, options)`
- Socket and UDP primitives: `Socket`, `UdpSocket`, `SocketIoReader`, `SocketIoWriter`
- Custom middleware structs with `handler` functions
