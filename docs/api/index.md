# API Overview

This page maps the explicit public API surface exposed by `httpx.zig`.

## Root Module (`httpx`)

The root module re-exports core types and convenience helpers so most apps can import only `httpx`.

### Client Operations (URL-first)

- `httpx.fetch(url, options)` — **primary unified fetch operation** (methods, typed JSON, headers, body)
- `httpx.get / post / put / patch / delete / head / options / trace / connect / request(url, options)`
- `httpx.getAll(urls)` — fetch multiple URLs concurrently
- `httpx.requestAll(requests)` — perform multiple custom requests concurrently
- `httpx.isOnline() / httpx.checkConnectivity(options)` — stateless connectivity probes
- Namespaced (not root globals): `client.download`, `client.graphql`, `client.lookupFileInfo`, `client.updateFile`, `httpx.Download.verifyFile`, `client.fetchSitemap`, `client.resolve`, `client.resolveUrl`

### Client Lifecycle

- `httpx.Client.init(allocator, io, config)` — initialize client with allocator, io, and configuration (or `.{}` for defaults)
- `client.close()` — purge the connection pool; `client.reset()` — close + clear DNS cache

### Server Lifecycle

- `httpx.Server.init(allocator, io, config)` — initialize server with allocator, io, and configuration (or `.{}` for defaults)
- `server.run()` — blocking loop; `server.start()` — background thread
- `server.requestShutdown()` / `server.stop()` / `server.pause()` / `server.resumeAccepting()`
- `server.localPort()` — actual bound port

### Configuration Types

- `httpx.ClientConfig` — client settings (protocols, timeouts, redirects, retries, pool, proxy, TLS, DNS cache)
- `httpx.ServerConfig` — server settings (host, port, strategy, body limits, protocols, docs, TLS, watcher, templates, logging)
- `httpx.RequestOptions` — per-request options (headers, query, body/json/form/text, auth, timeouts, proxy, TLS)
- `httpx.HttpVersion` — protocol version (`.auto`, `.http10`, `.http11`, `.http2`, `.http3`)
- `httpx.PortStrategy` — `.incremental`, `.strict`, `.exit`
- `httpx.DownloadOptions` / `DownloadResult` / `VerifyOptions` / `UpdateOptions` / `ExistingFilePolicy` / `ProgressMode`

### Server Types

- `httpx.Server`, `httpx.ServerConfig`, `httpx.Router`, `httpx.Context`, `httpx.Response`
- `httpx.tls.Listener`, `httpx.tls.ListenerConfig`, `httpx.tls.Request`, `httpx.tls.Response`

### Concurrency Helpers

- `client.getAll(urls)` / `client.requestAll(reqs)` (+ `httpx.getAll` / `httpx.requestAll`)
- `httpx.WorkerPool` / `httpx.Queue` (`src/concurrency/`)

### Network Helpers

- `client.resolve(host, options)` / `client.resolveUrl(url, options)`
- `httpx.resolve.Resolver`, `httpx.dns`, `httpx.socks5`, `httpx.proxy`
- `httpx.tcp`, `httpx.udp`, `httpx.Address`, `httpx.connectivity`

### Utility Aliases

- `httpx.mime.fromPath(path)` — extension-based MIME lookup
- `httpx.clock.millisNow()` / `sleepMillis(ms)` — monotonic clock helpers
- `httpx.Uri.parse(...)` — RFC 3986 URI parsing
- `httpx.quic.varint` — QUIC variable-length integers

### DNS Cache

- Client DNS cache via `ClientConfig.dnsCache` (`enable`, `ttlMs`, `negativeTtlMs`, `maxEntries`)

### WebSocket

- `httpx.websocket.Handshake.computeAccept / buildUpgradeRequest / validateUpgradeResponse`
- `httpx.websocket.Frame.parseFrameHeader / buildFrameHeader / applyMask / generateKey`

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
- HTTP/3 has a live client runtime path over QUIC + TLS 1.3 (`client.get` with `.httpVersion = .http3`, reliable networks) plus full protocol primitives (QPACK/HTTP3/QUIC framing).
- Cross-platform validation is maintained for Linux/Windows (x86, x86_64, aarch64) and macOS (x86_64, aarch64) build matrices.

## Customization and Callbacks

- Server event callbacks via `ServerConfig.logging = .{ .callback = onEvent }`
- Client event callbacks via `ClientConfig.eventCallback`
- Response JSON helpers: `Response.json(T)`, `Response.jsonAlloc(T, allocator)`
- Socket primitives: `httpx.tcp.Socket` / `httpx.tcp.Listener`, `httpx.udp`
- Custom middleware: `fn (ctx: *Context, next: NextFn) anyerror!Response`
