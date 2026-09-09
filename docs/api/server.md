# Server API

The `httpx.zig` server module provides a robust HTTP server with middleware support, routing, and proper context handling. The high-level runtime supports HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3.

## Protocol Support

| Protocol | Status | Features |
|----------|--------|----------|
| HTTP/1.0 | ✅ Full | Basic request/response |
| HTTP/1.1 | ✅ Full | Keep-Alive, chunked transfer, pipelining |
| HTTP/2 | ✅ Full | High-level server runtime over TCP plus full framing/HPACK/stream primitives |
| HTTP/3 | ✅ Full | High-level server runtime over UDP plus full HTTP/3/QPACK/QUIC primitives |

## Server

The `Server` struct manages the listener, router, and middleware processing.

### Initialization

```zig
const std = @import("std");
const httpx = @import("httpx");

const io = std.Io.Threaded.global_single_threaded.io();

// Initialize with default config
var server = try httpx.Server.init(allocator, io, .{});
defer server.deinit();

// Shorthand: explicit allocator + config
var server = try httpx.Server.init(allocator, io, .{
    .port = 3000,
    .host = "0.0.0.0",
});
defer server.deinit();

```zig
const std = @import("std");
const httpx = @import("httpx");

const io = std.Io.Threaded.global_single_threaded.io();

// Initialize with default config
var server = try httpx.Server.init(allocator, io, .{});
defer server.deinit();

// Initialize with custom config
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 3000,
    .portStrategy = .incremental,
    .maxPortAttempts = 32,
    .maxBody = 1024 * 1024, // 1MB
});
defer server.deinit();
```

### Configuration (`ServerConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `[]const u8` | `"0.0.0.0"` | Interface to bind to. |
| `port` | `u16` | `8080` | Port to listen on (`0` = ephemeral; read back via `localPort()`). |
| `portStrategy` | `PortStrategy` | `.incremental` | Startup behavior when the port is occupied (`.incremental`, `.strict`, `.exit`). |
| `maxPortAttempts` | `u16` | `50` | Port candidates to try when `portStrategy = .incremental`. |
| `maxBody` | `usize` | `8MB` | Largest accepted request body. |
| `maxConnections` | `usize` | `0` | Total connections `run()` serves before returning (`0` = unlimited; tests use small values to join deterministically). |
| `maxRequestsPerConn` | `usize` | `1000` | Max requests served per keep-alive connection. |
| `keepAlive` | `bool` | `false` | Honor HTTP/1.1 keep-alive on connections. |
| `allowLfLineEndings` | `bool` | `false` | Accept bare LF line endings when parsing requests. |
| `trustForwardedHeaders` | `bool` | `false` | Trust `X-Forwarded-*` headers from reverse proxies. |
| `trustedProxies` | `[]const []const u8` | `&.{}` | IPs/CIDRs allowed to supply forwarded headers. |
| `httpVersion` | `?HttpVersion` | `null` | Preferred HTTP version enforcement. |
| `http10` | `bool` | `true` | Enable HTTP/1.0 handling. |
| `http11` | `bool` | `true` | Enable HTTP/1.1 handling. |
| `http2` | `bool` | `true` | HTTP/2 cleartext/TLS server runtime path. |
| `http3` | `bool` | `false` | HTTP/3 server runtime path. |
| `logging` | `LoggingOptions` | `{}` | Event callback + level (silent by default). |
| `enableDocs` | `bool` | `true` | Mount `/openapi.json`, `/docs`, `/redoc` by default. |
| `docs` | `?docs.Config` | `null` | Overrides for docs routes when enabled. |
| `docsTitle` | `[]const u8` | `"HTTPX API"` | Title used by the docs UI. |
| `watch` | `bool` | `false` | Watch a directory and broadcast changes. |
| `watchDir` | `[]const u8` | `"."` | Directory to watch when `watch` is enabled. |
| `liveReload` | `bool` | `false` | Enable SSE/WebSocket live-reload endpoints + script injection. |
| `liveReloadPath` | `[]const u8` | `"/__httpx_liveReload"` | Mount path for the live-reload endpoint. |
| `templates` | `?TemplateConfig` | `null` | Template engine config (auto-discovers `templates/` when null). |
| `tls` | `?TlsServerConfig` | `null` | TLS/HTTPS config (certificate + private key). |

All `ServerConfig` fields are optional customizations. Omitted fields use the built-in defaults; `. {}` is the safe default.

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

Stops the server gracefully.

```zig
server.stop();
```

#### `use`

Adds a middleware to the global stack.

```zig
try server.use(httpx.middleware.logging);
try server.use(httpx.middleware.cors);
```

### Logging

HTTPX never prints on its own. Configure the server event callback to
observe requests (see [Observability: Logging](/observability/logging)):

```zig
fn onEvent(event: httpx.ServerEvent) void {
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
| `use(mw)` | Register global middleware |
| `static(mount, dir)` | Serve a filesystem directory |
| `spa(mount, dir)` | Serve a directory with SPA fallback |
| `metrics(path)` | Mount the Prometheus endpoint |
| `setStatusHandler(code, handler)` | Custom handler per status code |

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
    try server.use(httpx.middleware.logging);
    try server.use(httpx.middleware.cors);

    // Register routes
    try server.get("/", homePage);
    try server.get("/api/users", listUsers);
    try server.post("/api/users", createUser);
    try server.get("/api/users/:id", getUser);
    try server.put("/api/users/:id", updateUser);
    try server.delete("/api/users/:id", deleteUser);

    std.debug.print("Server listening on http://localhost:8080\n", .{});
    server.run();
}

fn homePage(ctx: *httpx.Context) !httpx.Response {
    return ctx.html("<h1>Welcome to httpx.zig!</h1>");
}

fn listUsers(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .users = &.{} });
}
```

## Explicit Server Types

### SSE Responses

Server-Sent Events use `httpx.sse.Writer.EventWriter` over a normal handler response
(see `examples/sse_server.zig` and [SSE](/web/sse)). There is no
`ctx.sse(...)` helper; parse inbound streams with `httpx.sse.Parser`
(`eventType`, `data`, `id`, `retryMs` fields on parsed events).

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
const router_mod = httpx.web.router;
var router = router_mod.Router.init(allocator);
defer router.deinit();
router.setNotFoundHandler(notFound);

fn notFound(ctx: *httpx.Context) anyerror!httpx.Response {
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
| `remoteAddress()` | Peer address (honors trusted `X-Forwarded-*`) |
| `scheme()` | `"https"` for TLS, else `"http"` |
| `host()` | Request host |
| `json(T)` | Parse request body as typed JSON into `T` |

### Response Helpers

| Method | Description |
|--------|-------------|
| `html(content)` / `htmlStatus(code, content)` | HTML responses |
| `text(content)` / `textStatus(code, content)` | Plain-text responses |
| `renderJson(value)` / `renderJsonStatus(code, value)` | JSON responses |
| `render(name, data)` / `renderStatus(code, name, data)` | Template responses |
| `xml(content)` / `rss(content)` / `atom(content)` | Feed responses |
| `robots(content)` / `sitemap(content)` | Crawler responses |
| `binary(bytes, contentType)` | Binary responses |
| `custom(code, contentType, content)` | Fully custom responses |
| `redirect(location, code)` | Redirect responses |
| `jsonFmt(fmt, args)` | Formatted JSON responses |

### Example Context Usage

```zig
fn getUser(ctx: *httpx.Context) anyerror!httpx.Response {
    // Get URL parameter
    const id = ctx.param("id") orelse return ctx.textStatus(400, "Missing user ID");

    // Get query parameter
    const format = ctx.queryParam("format") orelse "json";
    _ = format;

    // Get request header
    const auth = ctx.header("Authorization");
    _ = auth;

    // Return JSON response
    return ctx.renderJson(.{
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

fn myHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .message = "Hello World" });
}
```

### Handler Patterns

```zig
// Simple text response
fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello, World!");
}

// JSON response with status
fn created(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJsonStatus(201, .{ .id = 1, .created = true });
}

// Redirect
fn redirectHome(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.redirect("/", 302);
}

// Error handling
fn riskyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const data = doSomethingRisky() catch |err| {
        return ctx.renderJsonStatus(500, .{
            .error = "Internal Server Error",
            .message = @errorName(err),
        });
    };
    return ctx.renderJson(data);
}
```

## Static Files

Serve directories with `server.static(mount, dir)` (filesystem, with embedded-asset
fallback) instead of hand-rolled file handlers:

```zig
// Serves ./public/* under /static with ETag + conditional GET.
try server.static("/static", "./public");
```

For runnable demos see `examples/static_files.zig`, `examples/static_site.zig`,
and `examples/static_embedded.zig` (single-file embedded mode).

## Error Handling

Handle route-level errors in handlers and return explicit status codes as needed:

```zig
fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    const result = riskyOperation() catch |err| switch (err) {
        error.NotFound => return ctx.renderJsonStatus(404, .{ .error = "Not Found" }),
        error.Unauthorized => return ctx.renderJsonStatus(401, .{ .error = "Unauthorized" }),
        else => return ctx.renderJsonStatus(500, .{ .error = "Internal Server Error" }),
    };
    return ctx.renderJson(result);
}
```

## See Also

- [Middleware API](middleware.md) - Built-in middleware
- [Router API](router.md) - Advanced routing
- [Protocol API](protocol.md) - HTTP/2, HTTP/3
- [Server Guide](/guide/getting-started) - Usage guide
