# Testing Server API

The testing surface is exposed as `httpx.testing` and is built on the production
`httpx.Server`, transport, router, middleware, compression, and error handling.

## `httpx.testing.Server`

```zig
var server = try httpx.testing.Server.init(allocator, io, .{});
defer server.deinit();
```

| Member | Description |
|---|---|
| `init(allocator, io, cfg)` | Binds the local listener and creates capture state. `Config` is the production schema with loopback/port-0 defaults. |
| `start() !void` | Starts the production serving thread. The listener is already bound by `init`. |
| `stop() void` | Stops accepting, interrupts active connections, and joins the thread. Idempotent. |
| `deinit() void` | Stops if needed and releases routes, capture, and the production server. |
| `route(path, options) !void` | Registers a static or dynamic testing route. |
| `url(path) ![]u8` | Returns an owned absolute `http://` or `https://` URL. Free with the server allocator. |
| `capture(config) !void` | Replaces capture limits (validated by zigantic). Drops retained entries. |
| `requestCount() usize` | Total observed requests, including 404s and evicted entries. |
| `capturedCount() usize` | Number of retained requests. |
| `requests(allocator) ![]CapturedRequest` | Owned oldest-first snapshot. Free with `freeCaptured`. |
| `lastRequest(allocator) !?CapturedRequest` | Owned copy of the newest retained request. |
| `resetRequests() void` | Clears retained requests and resets the total. |
| `routeRequestCount(path) usize` | Requests handled by `route()` registrations at `path`. |
| `localPort() u16` | Actual bound port, including OS-assigned port 0. |
| `router() *Router` | Production router for advanced registration or `httpx.docs.init`. |
| `config() Config` | Effective validated production configuration. |
| `production() *httpx.Server` | The owned production server for APIs that require it. |

### Forwarded production methods

`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `add`, `group`,
`mount`, `register`, `use`, `static`, `spa`, `metrics`, `metricsSnapshot`,
`snapshot`, `setNotFoundHandler`, `setErrorHandler`, `setStatusHandler`, `rest`,
`graphql`, `isTls`, `isHttp3Ready`, `setTls`, `templates`, `http3`,
`localAddress`, `requestShutdown`, `pause`, `resumeAccepting`, `serve`, and
`run` forward directly to the production server. Signatures and validation are
unchanged.

## Testing configuration

`httpx.testing.Server.init` accepts the same fields as `httpx.Server.init`
except `.host = "127.0.0.1"` and `.port = 0`. All other defaults, validation, and
feature dependencies are shared with production. Option types are not exported;
pass the values inline:

```zig
var server = try httpx.testing.Server.init(allocator, io, .{
    .maxBody = 64 * 1024,
    .signals = .{ .enabled = false },
});
```

## `httpx.testing.RouteOptions`

| Field | Default | Description |
|---|---|---|
| `method` | `.GET` | Method when `.methods` is empty. |
| `methods` | `&.{}` | Register the same response for several methods. |
| `status` | `200` | Must be `100..599`. |
| `body` | `""` | Static body; copied at registration. |
| `contentType` | `null` | Optional `Content-Type`. |
| `headers` | `&.{}` | Extra response headers; names and values copied. |
| `handler` | `null` | Dynamic `fn (*httpx.router.Context) anyerror!httpx.router.Response`. |
| `delayMs` | `0` | Delay using the request I/O context. |
| `closeConnection` | `false` | Forces `Connection: close` after this response. |
| `location` | `null` | Adds a `Location` header without borrowing a temporary array. |
| `userData` | `null` | Opaque state handed to `.handler` as `ctx.userData`. |

Route options are validated with zigantic through `checkFirst`, matching
production configuration validation. Duplicate method+path registration returns
`error.DuplicateRoute` without modifying existing routes.

## Fixtures

| Helper | Result |
|---|---|
| `httpx.testing.text(body)` | `text/plain; charset=utf-8` |
| `httpx.testing.json(body)` | `application/json` |
| `httpx.testing.html(body)` | `text/html; charset=utf-8` |
| `httpx.testing.binary(body, type)` | Binary body with explicit media type |
| `httpx.testing.empty(status)` | Empty body with status |
| `httpx.testing.redirect(location, status)` | Location header and status |
| `httpx.testing.delayed(ms, options)` | Applies a delay |
| `httpx.testing.echo` | Handler mirroring request body/content type |

## `httpx.testing.websocket.EchoServer`

A real loopback WebSocket server for client development. It wraps
`httpx.testing.Server`, so the handshake, framing, authentication, and transport
are the production implementations.

```zig
var server = try httpx.testing.websocket.EchoServer.init(allocator, io, .{});
defer server.deinit();
try server.start();
defer server.stop();

var urlBuf: [128]u8 = undefined;
const url = try server.url("/ws", &urlBuf);

var client = try httpx.websocket.Client.init(allocator, io, .{
    .auth = .{ .scheme = .bearer, .token = "test-token" },
});
defer client.deinit();

var session = try client.connect(url);
defer session.deinit();
try session.sendText("ping");
```

| Member | Description |
|---|---|
| `init(allocator, io, cfg)` | Binds loopback, installs the authenticated and open echo routes. |
| `start()` / `stop()` / `deinit()` | Same lifecycle guarantees as `httpx.testing.Server`. |
| `url(path, buffer)` | Writes a `ws://127.0.0.1:<port><path>` URL. |
| `httpUrl(path, buffer)` | Writes the matching `http://` URL for non-upgrade checks. |
| `port()` | Actual bound port. |

`Config` fields are `token` (default `"test-token"`; `null` disables auth),
`path` (default `"/ws"`), `openPath` (default `"/ws-open"`),
`maxConnections`, `maxActive`, and `signalHandling` (default `false`).

## Capture types

`httpx.testing.CaptureConfig` is a zigantic schema:

| Field | Default |
|---|---|
| `enabled` | `true` |
| `maxEntries` | `256` |
| `maxBody` | `65536` |
| `maxHeader` | `16384` |

`httpx.testing.CapturedRequest` exposes:

| Member | Description |
|---|---|
| `method` | Production `Method` enum. |
| `path` | Clean request path, owned. |
| `query` | Raw query string without `?`, owned. |
| `headers` | Owned header copies. |
| `body` | Copied body, truncated at `maxBody`. |
| `bodySize` | Full body length before truncation. |
| `bodyTruncated` / `headersTruncated` | `bool` flags. |
| `header(name)` | Case-insensitive lookup. |
| `deinit()` | Releases one captured request. |
| `httpx.testing.freeCaptured(allocator, slice)` | Releases a snapshot. |

## Assertions

`expectStatus(response, expected)`, `expectBody(response, expected)`,
`expectBodyContains(response, needle)`, `expectHeader(response, name, value)`,
`expectNoHeader(response, name)`, and
`expectJsonBody(T, allocator, response)` work with `httpx.Client` responses and
any type exposing `status`, `body`, and `header(name)`. `expectJsonBody` returns
`std.json.Parsed(T)`.
