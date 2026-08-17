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
const httpx = @import("httpx");

// Initialize with default config
var server = httpx.Server.init(allocator);
defer server.deinit();

// Initialize with custom config
var server = httpx.Server.initWithConfig(allocator, .{
    .port = 3000,
    .host = "0.0.0.0",
    .port_conflict = .increment,
    .max_port_tries = 32,
    .max_body_size = 1048576, // 1MB
});
```

### Configuration (`ServerConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `[]const u8` | `"127.0.0.1"` | Interface to bind to. |
| `port` | `u16` | `8080` | Port to listen on. |
| `port_conflict` | `PortConflictStrategy` | `.fail` | Startup behavior when the preferred port is occupied (`.fail` or `.increment`). |
| `max_port_tries` | `u16` | `32` | Number of port candidates to try (including the initial port) when `port_conflict = .increment`. |
| `max_body_size` | `usize` | `10MB` | Max request body size. |
| `request_timeout_ms` | `u64` | `30000` | Timeout for request processing (enforced via socket receive timeout on each connection). |
| `keep_alive_timeout_ms` | `u64` | `60000` | Timeout for subsequent requests on a keep-alive connection. |
| `keep_alive` | `bool` | `true` | Enable HTTP Keep-Alive. |
| `max_connections` | `u32` | `1000` | Max concurrent connections. |
| `threads` | `u32` | `0` | Number of worker threads. `0` runs requests sequentially (single-threaded). `> 0` routes accepted connections through a task `Executor` thread pool of the specified size. |
| `http2_enabled` | `bool` | `false` | Enable HTTP/2 server runtime path. |
| `http3_enabled` | `bool` | `false` | Enable HTTP/3 server runtime path (UDP transport). |
| `http2_settings` | `Http2Settings` | `{}` | HTTP/2 SETTINGS frame defaults and limits. |
| `http3_settings` | `Http3Settings` | `{}` | HTTP/3 SETTINGS defaults (QPACK/field section limits). |
| `log_fn` | `?LogFn` | `null` | Optional server log callback. Leave unset to use tint.zig colored output to stderr. |
| `log_level` | `LogLevel` | `.info` | Minimum log level: `.debug`, `.info`, `.warn`, `.err`. Messages below this are silently dropped. |
| `unix_path` | `?[]const u8` | `null` | Optional Unix Domain Socket (AF_UNIX) path to bind and listen on. |
| `tls_enabled` | `bool` | `false` | Enable TLS for the server. Requires `tls_cert_path` and `tls_key_path`. |
| `tls_cert_path` | `?[]const u8` | `null` | Path to the TLS certificate file (PEM format). Required when `tls_enabled = true`. |
| `tls_key_path` | `?[]const u8` | `null` | Path to the TLS private key file (PEM format). Required when `tls_enabled = true`. |
| `tls_alpn_protocols` | `[]const []const u8` | `&.{ "h3", "h2", "http/1.1" }` | ALPN protocol list for TLS negotiation (e.g., `&.{"h2", "http/1.1"}`). |
| `enable_push` | `bool` | `true` | Enable HTTP/2 server push (PUSH_PROMISE) support. |

All `ServerConfig` fields are optional customizations. Omitted fields use the built-in defaults.

### HTTP/2 and HTTP/3 Runtime Configuration

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
    .http2_enabled = true,
    .http3_enabled = false,
    .http2_settings = .{
        .max_concurrent_streams = 100,
        .initial_window_size = 65_535,
    },
});
defer server.deinit();
```

### Port Conflict Handling

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
    .port_conflict = .increment,
    .max_port_tries = 32,
});
defer server.deinit();

try server.listen();
```

- `.fail`: return an error immediately if bind fails.
- `.increment`: try `port + 1`, `port + 2`, ... until success or attempts are exhausted.

### Methods

#### `listen`

Starts the server. This method blocks.

```zig
try server.listen();
```

#### `listenInBackground`

Starts the server in a background thread. Returns a thread handle that can be joined.

```zig
const thread = try server.listenInBackground();
// Server is now running in the background
// ...
server.stop(); // Stop when done
thread.join(); // Wait for the thread to finish
```

#### `listeningPort`

Returns the effective bound port (useful with `port_conflict = .increment`).

```zig
const p = server.listeningPort();
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
try server.use(httpx.middleware.logger());
```

### Logging

By default, HTTPX uses tint.zig for colored console output. Server logs appear as `HTTPX [INFO] Server listening on ...` with colored formatting based on log level.

**Default (tint.zig colored output):**
```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
});
```

**Disable all logs:**
```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .log_level = .err, // Only show errors (or .err + custom .log_fn)
});
```

**Custom logger (structured logging):**
```zig
const CustomLogger = struct {
    fn log(level: httpx.LogLevel, message: []const u8) void {
        std.debug.print("[{s}] {s}", .{ @tagName(level), message });
    }
};

var server = httpx.Server.initWithConfig(allocator, .{
    .log_fn = CustomLogger.log,
});
```

**Custom logger for middleware:**
```zig
try server.use(httpx.middleware.loggerWithConfig(.{ .log_fn = CustomLogger.log }));
```

If you want no request logging, omit `httpx.middleware.logger()` and leave `log_fn = null`.

### Routing Methods

| Method | Description |
|--------|-------------|
| `get(path, handler)` | Register GET route |
| `post(path, handler)` | Register POST route |
| `put(path, handler)` | Register PUT route |
| `delete(path, handler)` | Register DELETE route |
| `patch(path, handler)` | Register PATCH route |
| `head(path, handler)` | Register HEAD route |
| `trace(path, handler)` | Register TRACE route |
| `connect(path, handler)` | Register CONNECT route |
| `options(path, handler)` | Register OPTIONS route |
| `any(path, handler)` | Register GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/TRACE/CONNECT on the same path |
| `preRoute(hook)` | Register a pre-route hook (runs before route matching) |
| `global(handler)` | Register fallback handler for unmatched routes |
| `route(method, path, handler)` | Register any method |

### Quick Example

```zig
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    // Add middleware
    try server.use(httpx.middleware.logger());
    try server.use(httpx.middleware.cors(.{}));

    // Register routes
    try server.get("/", homePage);
    try server.get("/api/users", listUsers);
    try server.post("/api/users", createUser);
    try server.get("/api/users/:id", getUser);
    try server.put("/api/users/:id", updateUser);
    try server.delete("/api/users/:id", deleteUser);

    std.debug.print("Server listening on http://localhost:8080\n", .{});
    try server.listen();
}

fn homePage(ctx: *httpx.Context) !httpx.Response {
    return ctx.html("<h1>Welcome to httpx.zig!</h1>");
}

fn listUsers(ctx: *httpx.Context) !httpx.Response {
    return ctx.json(.{ .users = &.{} });
}
```

## Explicit Server Types

### `SseEvent`

Used by `ctx.sse(events)` for Server-Sent Events responses.

| Field | Type | Description |
|-------|------|-------------|
| `data` | `[]const u8` | Event payload body (required) |
| `event` | `?[]const u8` | Optional SSE event name |
| `id` | `?[]const u8` | Optional event id |
| `retry_ms` | `?u32` | Optional client reconnect hint |

### `PreRouteHook`

Hook signature used by `server.preRoute(...)`:

```zig
pub const PreRouteHook = *const fn (*Context) anyerror!void;
```

### Route Groups

Organize routes with a common prefix.

```zig
var api = server.router.group("/api/v1");
try api.get("/users", listUsers);
try api.post("/users", createUser);
try api.get("/users/:id", getUser);
try api.put("/users/:id", updateUser);
try api.delete("/users/:id", deleteUser);

var admin = server.router.group("/admin");
try admin.get("/dashboard", adminDashboard);
```

### Custom 404 Handler

```zig
server.router.setNotFound(fn(ctx: *httpx.Context) !httpx.Response {
    return ctx.status(404).json(.{
        .error = "Not Found",
        .path = ctx.request.path,
    });
});
```

## Context

The `Context` struct is passed to every route handler and middleware. It wraps the request and response objects.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `request` | `*Request` | The incoming request |
| `response` | `ResponseBuilder` | Response builder |
| `allocator` | `Allocator` | Request-scoped allocator |
| `params` | `StringMap` | URL path parameters |
| `data` | `StringMap(*anyopaque)` | User-defined request-scoped data |

### Request Accessors

| Method | Description |
|--------|-------------|
| `param(name)` | Get URL path parameter (`:id`, `:name`) |
| `query(name)` | Get query string parameter |
| `header(name)` | Get request header value |
| `authorization()` | Get raw `Authorization` header value |
| `bearerToken()` | Parse `Authorization: Bearer <token>` |
| `cookie(name)` | Get request cookie value by name |
| `hasContentType(media_type)` | Match request `Content-Type` (ignores parameters) |
| `isJson()` | True when request `Content-Type` is `application/json` |
| `jsonBody(T, opts)` | Parse request body as typed JSON, returning `std.json.Parsed(T)`. Caller must `defer parsed.deinit()`. |
| `jsonBodyLeaky(T, opts)` | Parse request body as typed JSON directly into `T` (leaky, no arena). |
| `jsonValue(opts)` | Parse request body as dynamic `std.json.Value`, returning `ParsedJson`. |
| `requireJson()` | Return error if Content-Type is not JSON. |
| `isFormUrlEncoded()` | True when request `Content-Type` is `application/x-www-form-urlencoded` |
| `accepts(media_type)` | True when request `Accept` allows a media type |
| `acceptsJson()` | True when request `Accept` allows `application/json` |

### Response Helpers

These methods allow fluent response chaining.

| Method | Description |
|--------|-------------|
| `status(code)` | Set HTTP status code |
| `setHeader(name, value)` | Set response header |
| `setCookie(name, value, options)` | Append `Set-Cookie` with Path/Domain/SameSite/Max-Age/Secure/HttpOnly |
| `removeCookie(name, options)` | Expire a cookie via `Max-Age=0` |
| `json(value)` | Send JSON response |
| `text(data)` | Send plain text |
| `html(data)` | Send HTML response |
| `file(path)` | Serve a file with extension-based content type |
| `fileAs(path, content_type)` | Serve a file with explicit content-type override |
| `download(path, filename)` | Serve a file as an attachment download |
| `fileWithOptions(path, options)` | Serve a file with cache/security/conditional-request controls |
| `chunked(data, trailers)` | Send chunked transfer body with optional trailers |
| `sse(events)` | Send Server-Sent Events payload |
| `redirect(url, code)` | Send redirect |
| `noContent()` | Send `204 No Content` |

### FileResponseOptions

`Context.fileWithOptions(path, options)` accepts `FileResponseOptions`:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `content_type` | `?[]const u8` | `null` | Override MIME type (otherwise extension-based lookup is used). |
| `cache_control` | `?[]const u8` | `null` | Optional `Cache-Control` response header. |
| `add_etag` | `bool` | `true` | Emit an `ETag` header for static responses. |
| `add_nosniff` | `bool` | `true` | Emit `X-Content-Type-Options: nosniff`. |
| `conditional_get` | `bool` | `true` | Evaluate `If-None-Match` and return `304 Not Modified` when matched. |

All `FileResponseOptions` fields are optional customizations; omitted fields use implicit defaults.

Example:

```zig
fn asset(ctx: *httpx.Context) !httpx.Response {
    return ctx.fileWithOptions("public/app.js", .{
        .cache_control = "public, max-age=300",
        .add_etag = true,
        .conditional_get = true,
    });
}
```

### Example Context Usage

```zig
fn getUser(ctx: *httpx.Context) !httpx.Response {
    // Get URL parameter
    const id = ctx.param("id") orelse return ctx.status(400).json(.{
        .error = "Missing user ID",
    });
    
    // Get query parameter
    const format = ctx.query("format") orelse "json";
    
    // Get request header
    const auth = ctx.header("Authorization");
    
    // Set response headers
    try ctx.setHeader("X-Request-Id", "12345");
    
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

fn myHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.json(.{ .message = "Hello World" });
}
```

### Handler Patterns

```zig
// Simple text response
fn hello(ctx: *httpx.Context) !httpx.Response {
    return ctx.text("Hello, World!");
}

// JSON response with status
fn created(ctx: *httpx.Context) !httpx.Response {
    return ctx.status(201).json(.{ .id = 1, .created = true });
}

// File download
fn download(ctx: *httpx.Context) !httpx.Response {
    try ctx.setHeader("Content-Disposition", "attachment; filename=\"report.pdf\"");
    return ctx.file("/path/to/report.pdf");
}

// Redirect
fn redirectHome(ctx: *httpx.Context) !httpx.Response {
    return ctx.redirect("/", 302);
}

// Error handling
fn riskyHandler(ctx: *httpx.Context) !httpx.Response {
    const data = doSomethingRisky() catch |err| {
        return ctx.status(500).json(.{
            .error = "Internal Server Error",
            .message = @errorName(err),
        });
    };
    return ctx.json(data);
}
```

## Static Files

You can return files directly from handlers with `ctx.file(path)`:

```zig
fn logo(ctx: *httpx.Context) !httpx.Response {
    return ctx.file("examples/multi_page_site/site/assets/images/httpx.zig-transparent.png");
}
```

`ctx.file(...)` and `ctx.fileAs(...)` both route through `ctx.fileWithOptions(...)`, so static responses can include ETag/conditional handling and `nosniff` headers by default.

For explicit website assets, combine a site root with wildcard routing:

```zig
const site_root = "examples/multi_page_site/site";

fn assets(ctx: *httpx.Context) !httpx.Response {
    const prefix = "/assets/";
    if (!std.mem.startsWith(u8, ctx.request.uri.path, prefix)) {
        return ctx.status(400).text("Invalid asset route");
    }
    const asset = ctx.request.uri.path[prefix.len..];
    if (asset.len == 0) return ctx.status(400).text("Missing asset path");
    if (std.mem.indexOf(u8, asset, "..") != null) return ctx.status(400).text("Invalid asset path");

    var buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/assets/{s}", .{ site_root, asset }) catch {
        return ctx.status(414).text("Path too long");
    };
    return ctx.file(full);
}

try server.get("/assets/*", assets);
```

This keeps HTML/CSS/JS/image files explicit and avoids ad-hoc runtime asset folders.

For runnable demos:

- `examples/static_files.zig`: explicit file routes (`/logo`, `/styles.css`, `/app.js`) plus directory wildcard routes (`/assets/*`, `/images/*`).
- `examples/multi_page_website.zig`: full website pages (`/`, `/about`, `/contact`) with static assets from `/static/*`.

## Error Handling

Handle route-level errors in handlers and return explicit status codes as needed:

```zig
fn handler(ctx: *httpx.Context) !httpx.Response {
    const result = riskyOperation() catch |err| switch (err) {
        error.NotFound => return ctx.status(404).json(.{ .error = "Not Found" }),
        error.Unauthorized => return ctx.status(401).json(.{ .error = "Unauthorized" }),
        else => return ctx.status(500).json(.{ .error = "Internal Server Error" }),
    };
    return ctx.json(result);
}
```

## See Also

- [Middleware API](middleware.md) - Built-in middleware
- [Router API](router.md) - Advanced routing
- [Protocol API](protocol.md) - HTTP/2, HTTP/3
- [Server Guide](/guide/getting-started) - Usage guide
