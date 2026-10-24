# API Overview

This page maps the explicit public API surface exposed by `httpx.zig`.

## Root Module (`httpx`)

The root module re-exports core types and namespaces. HTTP requests require an initialized client.

### Client Operations (URL-first)

- `client.fetch(url, options)` — **primary unified fetch operation** (methods, typed JSON, headers, body)
- `client.get / post / put / patch / delete / head / options / trace / connect / request(url, options)`
- `client.getAll(urls)` — fetch multiple URLs concurrently
- `client.requestAll(requests)` — perform multiple custom requests concurrently
- `client.checkConnectivity(options)` — connectivity probe using client I/O
- Additional operations: `client.download`, `client.graphql`, `client.lookupFileInfo`, `client.updateFile`, `httpx.client.download.verifyFile`, `client.fetchSitemap`, `client.resolve`, `client.resolveUrl`

### Client Lifecycle

- `httpx.Client.init(allocator, io, config)` — initialize client with allocator, io, and configuration (or `.{}` for defaults)
- `client.close()` — purge the connection pool; `client.reset()` — close + clear DNS cache

### Server Lifecycle

- `httpx.server.Server.init(allocator, io, config)` — initialize server with allocator, io, and configuration (or `.{}` for defaults)
- `server.run()` — blocking loop; `server.start()` — background thread
- `server.requestShutdown()` / `server.stop()` / `server.pause()` / `server.resumeAccepting()`
- `server.localPort()` — actual bound port

### Configuration Types

- Client settings: initialized with `.{}` on `httpx.Client.init` (protocols, timeouts, redirects, retries, pool, proxy, TLS, DNS cache)
- `httpx.server.Config` — server settings (host, port, strategy, body limits, protocols, docs, TLS, watcher, templates, logging)
- `httpx.client.requestOptions` — per-request options (headers, query, body/json/form/text, auth, timeouts, proxy, TLS)
- `httpx.HttpVersion` — protocol version (`.auto`, `.http10`, `.http11`, `.http2`, `.http3`)
- `httpx.server.PortStrategy` — `.incremental`, `.strict`, `.exit`
- `httpx.client.downloadOptions` / `downloadResult` / `verifyOptions` / `updateOptions` / `existingFilePolicy` / `progressMode`

### Server Types

- `httpx.server.Server`, `httpx.server.Config`, `httpx.web.router.Router`, `httpx.web.router.Context`, `httpx.web.router.Response`
- `httpx.protocols.tls.Listener`, `httpx.protocols.tls.ListenerConfig`, `httpx.protocols.tls.Request`, `httpx.protocols.tls.Response`

### Concurrency Helpers

- `client.getAll(urls)` / `client.requestAll(reqs)`
- `httpx.concurrency.Pool` / `httpx.concurrency.Queue` (`src/concurrency/`)

### Network Helpers

- `client.resolve(host, options)` / `client.resolveUrl(url, options)`
- `httpx.net.resolve.Resolver`, `httpx.net.dns`, `httpx.net.socks5`, `httpx.net.proxy`
- `httpx.tcp`, `httpx.udp`, `httpx.Address`, `httpx.net.connectivity`

### Utility Aliases

- `httpx.mime.fromPath(path)` — extension-based MIME lookup
- `httpx.clock.millisNow(io)` / `sleepMillis(io, ms)` — monotonic clock helpers
- `httpx.Uri.parse(...)` — RFC 3986 URI parsing
- `httpx.protocols.quic.varint` — QUIC variable-length integers

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
