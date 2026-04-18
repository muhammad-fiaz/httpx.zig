# API Overview

This page maps the explicit public API surface exposed by `httpx.zig`.

## Root Module (`httpx`)

The root module re-exports core types and convenience helpers so most apps can import only `httpx`.

### Client Helpers

- `httpx.fetch(url)`
- `httpx.send(method, url, options)`
- `httpx.get/post/put/delete/del/patch/head/trace/connect/options/opts(...)`
- Explicit allocator overrides: `httpx.fetchWithAllocator(...)`, `httpx.sendWithAllocator(...)`, and `*WithAllocator` variants for each alias.

### Optional Client Builder Helpers

- `httpx.ClientConfig.defaults().withDefaultHeaders(...)`
- `httpx.ClientConfig.defaults().withFollowRedirects(...)`
- `httpx.ClientConfig.defaults().withHttp2Settings(...)`
- `httpx.ClientConfig.defaults().withHttp3Settings(...)`
- `httpx.ClientConfig.defaults().withSslVerification(...)`
- `httpx.ClientConfig.defaults().withKeepAlive(...)`
- `httpx.ClientConfig.defaults().withMaxResponseSize(...)`
- `httpx.RequestOptions.defaults().withQueryParams(...)`
- `httpx.RequestOptions.defaults().withFormUrlEncoded(...)`
- `httpx.RequestOptions.defaults().withBearerToken(...)`
- `httpx.RequestOptions.defaults().withBasicAuth(...)`
- `httpx.RequestOptions.defaults().withVersion(...)`
- `httpx.RequestOptions.defaults().withHttp2()`
- `httpx.RequestOptions.defaults().withHttp3()`
- `httpx.BasicAuth`

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
- `httpx.resolveAddress(host, port)`
- `httpx.resolveAllAddresses(allocator, host, port)`
- `httpx.parseHostAndPort(input, default_port)`
- `httpx.parseAndResolveAddress(input, default_port)`
- `httpx.isIpAddress/isIp4Address/isIp6Address(...)`

### Utility Aliases

- `httpx.queryValue(...)`
- `httpx.parseQueryValue(...)`
- `httpx.parseSetCookiePair(...)`
- `httpx.parseCookiePair(...)`
- `httpx.mimeTypeFromPath(...)`
- `httpx.mimeTypeFromPathOr(...)`
- `httpx.mimeTypeFromPathWith(...)`
- `httpx.MimeMapping` / `httpx.MimeRegistry`
- `httpx.defaultMimeMappings`
- `httpx.encodeVarInt(...)`
- `httpx.decodeVarInt(...)`

## API Groups

- [Client API](/api/client)
- [Concurrency API](/api/concurrency)
- [Core API](/api/core)
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
