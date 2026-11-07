# Server API

The `httpx.zig` server module provides a robust HTTP server with middleware support, routing, and proper context handling. The high-level runtime supports HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3.

## Protocol Support

| Protocol | Status | Features |
|----------|--------|----------|
| HTTP/1.0 | ✅ Full | Basic request/response |
| HTTP/1.1 | ✅ Full | Keep-Alive, chunked transfer, trailers |
| HTTP/2 | ✅ Full | High-level server runtime over TCP/TLS plus full framing/HPACK/stream primitives |
| HTTP/3 | ✅ Full | High-level server runtime over UDP + QUIC/TLS 1.3 with loss recovery, NewReno congestion control, 0-RTT, Retry, v1/v2 version negotiation, and pooled connections |

## Server

The `Server` struct manages the listener, router, and middleware processing.

### Initialization

```zig
const std = @import("std");
const httpx = @import("httpx");

var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();
const io = std.Io.Threaded.global_single_threaded.io();

// Initialize with default config
var server = try httpx.Server.init(allocator, io, .{});
defer server.deinit();

// Initialize with custom config
var custom_server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 3000,
    .portStrategy = .incremental,
    .maxPortAttempts = 32,
    .maxBody = 1024 * 1024, // 1MB
});
defer custom_server.deinit();

// Environment variables are application policy; map them explicitly.
const port = if (httpx.env.get("PORT")) |value|
    try std.fmt.parseInt(u16, value, 10)
else
    8080;
var env_server = try httpx.Server.init(allocator, io, .{
    .host = httpx.env.get("HOST") orelse "0.0.0.0",
    .port = port,
    .workerCount = httpx.env.getInt(u16, "HTTPX_WORKERS") orelse 0,
});
defer env_server.deinit();
```

### Configuration (inline `.{}` options)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `[]const u8` | `"0.0.0.0"` | Interface to bind to. |
| `port` | `u16` | `8080` | Port to listen on (`0` = ephemeral; read back via `localPort()`). |
| `portStrategy` | `PortStrategy` | `.incremental` | Startup behavior when the port is occupied (`.incremental`, `.strict`, `.exit`). |
| `maxPortAttempts` | `u16` | `50` | Port candidates to try when `portStrategy = .incremental`. |
| `maxBody` | `usize` | `8MB` | Largest accepted request body. |
| `maxConnections` | `usize` | `0` | Total connections successfully queued before `run()` stops accepting (`0` = unlimited). |
| `maxConcurrentConnections` | `usize` | `128` | Bound across connections being processed or queued. New connections above the limit are closed. Must be greater than zero. |
| `maxQueuedConnectionTasks` | `usize` | `128` | Bounded worker queue capacity. Newly accepted sockets are closed when the queue is full. Must be greater than zero. |
| `workerCount` | `u16` | `0` | Fixed worker count; zero selects up to 16 CPUs, capped by `maxConcurrentConnections`. |
| `initialRequestTimeoutMs` | `u32` | `5000` | Maximum time from accept to the first request bytes and protocol sniff. Zero disables the deadline. |
| `headerReadTimeoutMs` | `u32` | `10000` | Absolute time to finish request headers after the first byte. Zero disables the deadline. |
| `requestBodyTimeoutMs` | `u32` | `30000` | Absolute time to receive a complete body. Zero disables the deadline. |
| `writeTimeoutMs` | `u32` | `30000` | Absolute time allowed for an interim or final response write. Zero disables the deadline. |
| `keepAliveIdleTimeoutMs` | `u32` | `30000` | Maximum wait for the next request on an HTTP/1 keep-alive connection. Zero disables the deadline. |
| `maxRequestsPerConn` | `usize` | `1000` | Max requests served per keep-alive connection. |
| `keepAlive` | `bool` | `false` | Honor HTTP/1.1 keep-alive on connections. |
| `compression` | `compression.Config` | `{}` | Automatic response compression codec settings for HTTP/1.1, HTTP/2, and HTTP/3. |
| `maxCompressionInput` | `usize` | `128 KiB` | Largest response body the server will compress automatically. |
| `allowLfLineEndings` | `bool` | `false` | Accept bare LF line endings when parsing requests. |
| `trustForwardedHeaders` | `bool` | `false` | Trust `X-Forwarded-*` headers from reverse proxies. |
| `trustedProxies` | `[]const []const u8` | `&.{}` | IPs/CIDRs allowed to supply forwarded headers; forwarded chains skip entries matching these rules. Empty trusts every peer when forwarding is enabled. |
| `httpVersion` | `?HttpVersion` | `null` | Preferred HTTP version enforcement. |
| `http10` | `bool` | `true` | Enable HTTP/1.0 handling. |
| `http11` | `bool` | `true` | Enable HTTP/1.1 handling. |
| `http2` | `bool` | `true` | HTTP/2 cleartext/TLS server runtime path. |
| `http3` | `bool` | `false` | HTTP/3 server runtime path. |
| `http3Retry` | `bool` | `false` | Require a Retry token before accepting the QUIC Initial, validating the peer address and limiting amplification. |
| `http3RetryKey` | `?[32]u8` | `null` | HMAC key for Retry tokens; a fresh random key per connection is used when null. |
| `http3MaxIdleTimeoutMs` | `u64` | `30000` | QUIC idle timeout; effective value is the minimum of this and the peer's advertised timeout. Zero disables enforcement. |
| `http3InitialMaxData` | `u64` | `1048576` | Connection-level QUIC receive window. |
| `http3InitialMaxStreamDataBidiLocal` | `u64` | `65535` | Receive window for locally initiated bidirectional streams. |
| `http3InitialMaxStreamDataBidiRemote` | `u64` | `65535` | Receive window for peer-initiated bidirectional streams. |
| `http3InitialMaxStreamDataUni` | `u64` | `65535` | Receive window for peer-initiated unidirectional streams. |
| `http3MaxStreamsBidi` | `u64` | `128` | Concurrent bidirectional streams a client may open. |
| `http3MaxStreamsUni` | `u64` | `128` | Concurrent unidirectional streams a client may open. |
| `http3MaxUdpPayload` | `usize` | `1472` | Advertised QUIC max UDP payload (validated 1200–65527 bytes). |
| `logging` | `LoggingOptions` | `{}` | Event callback + level (silent by default). |
| `enableDocs` | `bool` | `true` | Mount `/openapi.json`, `/docs`, `/redoc` by default. |
| `docs` | `?docs.Config` | `null` | Overrides for docs routes when enabled; `docs.title` names the document. |
| `watch` | `bool` | `false` | Watch a directory and broadcast changes. |
| `watchDir` | `[]const u8` | `"."` | Directory to watch when `watch` is enabled. |
| `liveReload` | `bool` | `false` | Enable the SSE live-reload endpoint and script injection. |
| `liveReloadPath` | `[]const u8` | `"/__httpx_liveReload"` | Mount path for the live-reload endpoint. |
| `templates` | `?TemplateConfig` | `null` | Template engine config (auto-discovers `templates/` when null). |
| `tls` | `?tls.Server.Config` | `null` | TLS/HTTPS config (certificate + private key). |

All server settings are passed inline as the final `.{}` argument to `httpx.Server.init`. Omitted fields use the built-in defaults; `.{}` is the safe default.

### Operational Deployment Environment Configuration

Server configuration remains pure explicit Zig options via `.{}`. If an application wishes to bind ports or hosts from process environment variables or a `.env` file, it selectively uses `httpx.env`:

```zig
// Read operational deployment values via httpx.env utils:
var server = try httpx.Server.init(allocator, io, .{
    .host = httpx.env.get("HOST") orelse "0.0.0.0",
    .port = httpx.env.getInt(u16, "PORT") orelse 8080,
    .workerCount = httpx.env.getInt(u16, "WORKERS") orelse 0,
});
defer server.deinit();

// Or read from a loaded .env file:
var envStore = try httpx.env.loadFile(allocator, ".env");
defer envStore.deinit();

var env_server = try httpx.Server.init(allocator, io, .{
    .host = envStore.get("HOST") orelse "0.0.0.0",
    .port = if (envStore.get("PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 8080,
});
defer env_server.deinit();
```

Application routes, middleware composition, handler logic, and internal buffers remain explicit code options configured via `httpx.Server.init`.

### Connection handling and concurrency

The accept loop submits connections to a fixed worker pool. The server tracks
active and queued connections together and admits no more than
`maxConcurrentConnections`; the worker queue independently holds at most
`maxQueuedConnectionTasks`. A full queue or connection limit closes the newly
accepted socket, so the effective queued capacity is bounded by both settings.
`maxConnections` is a separate lifetime limit and counts successfully queued
connections.

The timeout fields are absolute deadlines for each I/O phase, not inactivity
windows that restart after every byte. A server-owned monitor interrupts the
timed-out direction on accepted sockets so a blocked I/O operation releases
its worker. A zero timeout disables the corresponding deadline. Graceful
`requestShutdown()` stops acceptance, lets active requests finish within their
I/O deadlines, and closes queued sockets without starting new requests.
`stop()` interrupts active socket I/O immediately. A user handler that blocks
without returning is not forcibly cancelled.

Route registration and configuration must finish before `run()` starts.
Handlers and the logging callback may be invoked concurrently from different
worker threads, so shared application state must be synchronized by the
application.

### Server Lifecycle

```zig
server.run();              // blocking accept loop
const thread = try server.start(); // non-blocking, returns std.Thread
server.pause();            // pause accepting new connections
server.resumeAccepting();  // resume accepting new connections
server.requestShutdown();  // graceful shutdown (drains in-flight requests)
server.stop();             // immediate shutdown
const port = server.localPort(); // actual bound port (useful with .port = 0)
```

### HTTP/2 and HTTP/3 Runtime Configuration

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .http2 = true,
    .http3 = false,
});
defer server.deinit();
```

### Port Conflict Handling

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .portStrategy = .incremental,
    .maxPortAttempts = 32,
});
defer server.deinit();

server.run();
```

- `.strict`: return an error immediately if bind fails.
- `.incremental`: try `port + 1`, `port + 2`, ... until success or attempts are exhausted.
- `.exit`: fail if the port is occupied.

### Methods

#### `run`

Starts the server. This method blocks.

```zig
server.run();
```

#### `start`

Starts the server in a background thread. Returns a thread handle that can be joined.

```zig
const thread = try server.start();
// Server is now running in the background
// ...
server.stop(); // Stop when done
thread.join(); // Wait for the thread to finish
```

#### `localPort`

Returns the effective bound port (useful with `.port = 0` or `portStrategy = .incremental`).

```zig
const p = server.localPort();
_ = p;
```

#### `stop`

Stops the server immediately and closes active sockets.

```zig
server.stop();
```

#### `use`

Adds a middleware to the global stack.

```zig
try server.use(httpx.middleware.helmet);
try server.use(httpx.middleware.cors);
```

### Logging

HTTPX never prints on its own. Configure the server event callback to
observe requests (see [Observability: Logging](/observability/logging)):

```zig
fn onEvent(event: httpx.logging.ServerEvent) void {
    if (event.kind == .requestCompleted) {
        std.debug.print("{s} {s} {d}\n", .{ event.method, event.path, event.status });
    }
}

var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .logging = .{ .callback = onEvent },
});
```

Omit `.logging.callback` (the default) for fully silent operation.

### Routing Methods

| Method | Description |
|--------|-------------|
| `get(path, handler)` | Register GET route |
| `post(path, handler)` | Register POST route |
| `put(path, handler)` | Register PUT route |
| `delete(path, handler)` | Register DELETE route |
| `patch(path, handler)` | Register PATCH route |
| `head(path, handler)` | Register HEAD route |
| `options(path, handler)` | Register OPTIONS route |
| `rest()` | Typed REST controller sharing this server's allocator and `io` |
| `graphql(schema, cfg)` | Mount a GraphQL endpoint (removed by `deinit`) |
| `use(mw)` | Register global middleware |
| `static(mount, dir)` | Serve a filesystem directory |
| `spa(mount, dir)` | Serve a directory with SPA fallback |
| `metrics(path)` | Mount the Prometheus endpoint |
| `setStatusHandler(code, handler)` | Custom handler per status code |

### `httpx.Server` — Typed REST

`httpx.Server` is the inbound owner. Create it and the outbound client
separately, both from the same allocator and `std.Io`:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
});
defer server.deinit();

var client = httpx.Client.init(allocator, io, .{ .timeoutMs = 10_000 });
defer client.deinit();

const upstream = try client.get("https://example.com/health", .{});
defer upstream.deinit();
```

Routes are registered with the path as the first argument and one `.{}` options
literal as the second.

The handler's return type selects the mode automatically:

- `!httpx.Schema(T)` → typed REST endpoint (JSON body decoding plus OpenAPI 3.1).
- `!httpx.router.Response` → raw `HandlerFn` route with the same metadata fields.

| Method | Description |
|--------|-------------|
| `server.get(path, .{ .handler, ... })` | GET |
| `server.post(path, .{ .handler, ... })` | POST — typed handlers decode the JSON body |
| `server.put(path, ...)` / `server.patch(path, ...)` | PUT / PATCH |
| `server.delete(path, ...)` | DELETE |
| `server.head(path, ...)` / `server.options(path, ...)` | HEAD / OPTIONS |
| `server.add(.METHOD, path, .{ .handler, ... })` | Explicit method dispatch |

A bare handler is also accepted: `server.get("/ping", ping)`. Options are anonymous
struct literals — all fields are optional:

```zig
try server.post("/users", .{
    .handler = createUser,
    .operationId = "createUser",
    .summary = "Create a user",
    .description = "Creates a user and returns the stored record.",
    .tags = &.{"users"},
    .deprecated = false,
    .security = &.{},
    .params = &.{
        .{ .name = "id", .in = .path, .required = true, .schema = httpx.rest.schemaOf(u64) },
        .{ .name = "expand", .in = .query, .schema = httpx.rest.schemaOf(bool) },
        .{ .name = "X-Request-Id", .in = .header, .schema = httpx.rest.schemaOf([]const u8) },
    },
    .responses = &.{
        .{ .status = 201, .description = "Created", .schema = httpx.rest.schemaOf(User) },
        .{ .status = 422, .description = "Invalid user" },
    },
    .request = .{ .content = .json, .description = "User to create", .required = true },
    .internal = false,
    .mediaType = "application/json; charset=utf-8",
});

// Raw handler route: same verb, no schema derivation.
try server.get("/health", .{ .handler = healthCheck, .summary = "Liveness" });
```

#### Parameters and responses

Typed endpoints derive one response from the handler's return type and
synthesize path parameters from pattern converters (`{id:int}`). State them
explicitly when the contract is wider than the return type:

| Option | Type | Default | Description |
|---|---|---|---|
| `params` | `[]const httpx.rest.Param` | `&.{}` | Path, query, header, and cookie parameters |
| `responses` | `[]const httpx.rest.ResponseDesc` | Derived | Response list; replaces the derived response |
| `request` | `?httpx.rest.RequestBody` | Derived | JSON request-body description/required override |
| `internal` | `bool` | `false` | Exclude the route from OpenAPI |
| `mediaType` | `[]const u8` | `application/json; charset=utf-8` | Response media type |

`httpx.rest.schemaOf(T)` returns the `*const Schema` that `Param.schema` and
`ResponseDesc.schema` require, so the same Zig types drive OpenAPI and JSON
decoding. Struct fields use their exact names (quoted identifiers included).
Explicit path parameters replace synthesized ones for the same name; undeclared
path parameters stay synthesized from the converter.

```zig
try server.get("/users/{id:int}", .{
    .handler = getUser,
    .params = &.{
        .{ .name = "id", .in = .path, .required = true, .schema = httpx.rest.schemaOf(u64) },
        .{ .name = "expand", .in = .query, .schema = httpx.rest.schemaOf(bool) },
    },
    .responses = &.{
        .{ .status = 200, .description = "User found", .schema = httpx.rest.schemaOf(User) },
        .{ .status = 404, .description = "User not found" },
    },
});
```

`.internal = true` keeps infrastructure routes (health probes, docs assets)
out of the generated document while still serving them. Typed handlers decode
JSON only, so `.request.content` must stay `.json`; setting `.request` on a
handler without a request parameter is a compile error.

#### Results: `Schema(T).result(.{ ... })`

```zig
fn createUser(ctx: *httpx.router.Context, req: CreateUser) !httpx.Schema(User) {
    _ = ctx;
    return httpx.Schema(User).result(.{
        .status = .created,
        .body = .{ .id = 101, .name = req.name },
    });
}
```

`result` accepts `.status`, `.body`, `.headers`, and `.mediaType`, all optional.
Shorthands: `.ok(body)`, `.created(body)`, `.accepted(body)`, `.noContent()`,
`.of(status, body)`. Use `httpx.Schema(void)` (or `httpx.Empty`) for bodiless
responses.

#### JSON media types

JSON detection is rule-based, so no media type has to be registered with the
library first. Any subtype ending in the `+json` structured-syntax suffix is
accepted (`problem+json`, `merge-patch+json`, `json-patch+json`, `vnd.api+json`,
`hal+json`, `ld+json`, `activity+json`, `schema+json`, `geo+json`, `jrd+json`,
`webpush-options+json`, `graphql-response+json`, and the `prs.` / `x.` trees),
as are `application/json`, legacy `text/json` / `application/x-json`, and
`application/csp-report`. `json5`, NDJSON/JSONL, and JSON text sequences have
separate classifications because they require different parsers. Parameters
are validated and ignored for classification; type tokens are case-insensitive.
The single entry point is `httpx.json.isJsonMediaType`.

A present-but-non-JSON `Content-Type` is `415`; a malformed body is `400` with a
JSON envelope `{"error": ..., "status": ...}`.

#### Keys that are not Zig identifiers

JSON keys are arbitrary strings and are preserved exactly — nothing in the
library restricts them to Zig identifier rules. Declare them as quoted fields:

```zig
const CreateUser = struct {
    @"user-name": []const u8,
    @"@context": []const u8,
};
const User = struct {
    id: u64,
    @"user-name": []const u8,
    @"@context": []const u8,
};

try server.post("/users", .{
    .handler = createUser, // fn (ctx, CreateUser) !httpx.Schema(User)
});
```

Requests are decoded with those exact names, responses are encoded with them,
and the OpenAPI document lists them. For shapes that are not known ahead of
time use `std.json.Value` or `httpx.json.Object` and read keys dynamically
(`.get("user-name")`, `.getIgnoreCase("content-type")`). See
[JSON typed structs](/api/data#typed-structs).

### Quick Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{});
    defer server.deinit();

    // Add middleware
    try server.use(httpx.middleware.helmet);
    try server.use(httpx.middleware.cors);

    // Register routes
    try server.get("/", homePage);
    try server.get("/api/users", listUsers);
    try server.post("/api/users", createUser);
    try server.get("/api/users/{id}", getUser);
    try server.put("/api/users/{id}", updateUser);
    try server.delete("/api/users/{id}", deleteUser);

    std.debug.print("Server listening on http://localhost:8080\n", .{});
    server.run();
}

fn homePage(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.html("<h1>Welcome to httpx.zig!</h1>");
}

fn listUsers(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .users = &.{} });
}
```

## Explicit Server Types

### SSE Responses

Server-Sent Events use `httpx.sse.Event.Writer` over a normal handler response
(see `examples/sseServer.zig` and [SSE](/api/sse)). The router buffers each
response, so a handler emits a finite batch of events; long-lived SSE needs a
custom HTTP/1.1 connection loop. There is no `ctx.sse(...)` helper; parse
inbound streams with `httpx.sse.Event.Parser` (`eventType`, `data`, `id`,
`retryMs` fields on parsed events).

### Route Groups

Register versioned route families explicitly (no group helper object):

```zig
try server.get("/api/v1/users", listUsers);
try server.post("/api/v1/users", createUser);
try server.get("/api/v1/users/{id}", getUser);
```

Path parameters use `{name}` segments and are read with `ctx.param("id")`.

### Custom 404 Handler

```zig
var router = httpx.Router.init(allocator);
defer router.deinit();
router.setNotFoundHandler(notFound);

fn notFound(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.textStatus(404, "Not Found");
}
```

## Context

The `Context` struct is passed to every route handler and middleware.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `Allocator` | Request-scoped allocator |
| `path` | `[]const u8` | Clean request path |
| `method` | `Method` | Request method |
| `headers` | `[]Header` | Request headers |
| `body` | `[]u8` | Request body bytes |
| `isTls` | `bool` | Whether the connection uses TLS |

### Request Accessors

| Method | Description |
|--------|-------------|
| `param(name)` | Get URL path parameter (`{id}`) |
| `queryParam(name)` | Get query string parameter |
| `header(name)` | Get request header value (case-insensitive) |
| `cookie(name)` | Get request cookie value by name |
| `bearerToken()` | Parse `Authorization: Bearer <token>` |
| `basicAuth()` | Parse `Authorization: Basic ...` into username/password |
| `remoteAddress()` | Peer address (honors `X-Forwarded-*` only from configured trusted proxies) |
| `scheme()` | `"https"` for TLS, else `"http"` |
| `host()` | Request host |
| `json(T)` | Parse request body as typed JSON into `T` |

### Response Helpers

| Method | Description |
|--------|-------------|
| `html(content)` / `htmlStatus(code, content)` | HTML responses |
| `text(content)` / `textStatus(code, content)` | Plain-text responses |
| `json(value)` / `jsonStatus(code, value)` | JSON responses |
| `render(name, data)` / `renderStatus(code, name, data)` | Template responses |
| `xml(content)` / `rss(content)` / `atom(content)` | Feed responses |
| `robots(content)` / `sitemap(content)` | Crawler responses |
| `binary(bytes, contentType)` | Binary responses |
| `custom(code, contentType, content)` | Fully custom responses |
| `redirect(location, code)` | Redirect responses |
| `jsonFmt(fmt, args)` | Formatted JSON responses |

### Example Context Usage

```zig
fn getUser(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    // Get URL parameter
    const id = ctx.param("id") orelse return ctx.textStatus(400, "Missing user ID");

    // Get query parameter
    const format = ctx.queryParam("format") orelse "json";
    _ = format;

    // Get request header
    const auth = ctx.header("Authorization");
    _ = auth;

    // Return JSON response
    return ctx.json(.{
        .id = id,
        .name = "John Doe",
        .email = "john@example.com",
    });
}
```

## Handlers

Handlers are functions that take a `*Context` and return a `!Response`.

```zig
const Handler = *const fn (*Context) anyerror!Response;

fn myHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .message = "Hello World" });
}
```

### Handler Patterns

```zig
// Simple text response
fn hello(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.text("Hello, World!");
}

// JSON response with status
fn created(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.jsonStatus(201, .{ .id = 1, .created = true });
}

// Redirect
fn redirectHome(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.redirect("/", 302);
}

// Error handling
fn riskyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = doSomethingRisky() catch |err| {
        return ctx.jsonStatus(500, .{
            .error = "Internal Server Error",
            .message = @errorName(err),
        });
    };
    return ctx.json(data);
}
```

## Static Files

Serve directories with `server.static(mount, dir)` (filesystem, with embedded-asset
fallback) instead of hand-rolled file handlers:

```zig
// Serves ./public/* under /static with ETag + conditional GET.
try server.static("/static", "./public");
```

For runnable demos see `examples/staticFiles.zig`, `examples/staticSite.zig`,
and `examples/staticEmbedded.zig` (single-file embedded mode).

## Error Handling

Handle route-level errors in handlers and return explicit status codes as needed:

```zig
fn handler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const result = riskyOperation() catch |err| switch (err) {
        error.NotFound => return ctx.jsonStatus(404, .{ .error = "Not Found" }),
        error.Unauthorized => return ctx.jsonStatus(401, .{ .error = "Unauthorized" }),
        else => return ctx.jsonStatus(500, .{ .error = "Internal Server Error" }),
    };
    return ctx.json(result);
}
```

## See Also

- [Middleware API](middleware.md) - Built-in middleware
- [Router API](router.md) - Advanced routing
- [Protocol API](protocol.md) - HTTP/2, HTTP/3
- [Server Guide](/guide/getting-started) - Usage guide

