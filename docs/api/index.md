# API Overview

This page maps the explicit public API surface exposed by `httpx.zig`.

## Root Module (`httpx`)

The root module re-exports core types and convenience helpers so most apps can import only `httpx`.

### Client Helpers

- `httpx.fetch(allocator, url)`
- `httpx.send(allocator, method, url, options)`
- `httpx.get/post/put/delete/del/patch/head/options/opts(...)`

### Concurrency Helpers

- `httpx.all(...)`
- `httpx.any(...)`
- `httpx.race(...)`
- `httpx.allSettled(...)`
- `httpx.first(...)` (alias for `any`)
- `httpx.fastest(...)` (alias for `race`)
- `httpx.settled(...)` (alias for `allSettled`)
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
- HTTP/2 and HTTP/3 are fully implemented protocol primitives and can be integrated through protocol/network layers.
- Cross-platform support is maintained for Linux, Windows, macOS, and BSD-family targets.
