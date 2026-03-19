# Server API

The `httpx.zig` server module provides a robust HTTP server with middleware support, routing, and proper context handling. Supports HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 protocols.

## Protocol Support

| Protocol | Status | Features |
|----------|--------|----------|
| HTTP/1.0 | ✅ Full | Basic request/response |
| HTTP/1.1 | ✅ Full | Keep-Alive, chunked transfer, pipelining |
| HTTP/2 | ⚠️ Partial | Protocol primitives available; high-level server currently handles HTTP/1.x requests |
| HTTP/3 | ⚠️ Partial | Protocol primitives available; high-level server currently handles HTTP/1.x requests |

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
    .max_body_size = 1048576, // 1MB
});
```

### Configuration (`ServerConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `[]const u8` | `"127.0.0.1"` | Interface to bind to. |
| `port` | `u16` | `8080` | Port to listen on. |
| `max_body_size` | `usize` | `10MB` | Max request body size. |
| `request_timeout_ms` | `u64` | `30000` | Timeout for request processing. |
| `keep_alive_timeout_ms` | `u64` | `60000` | Timeout for keep-alive requests. |
| `keep_alive` | `bool` | `true` | Enable HTTP Keep-Alive. |
| `max_connections` | `u32` | `1000` | Max concurrent connections. |
| `threads` | `u32` | `0` | Reserved for future thread configuration. |

### Methods

#### `listen`

Starts the server. This method blocks.

```zig
try server.listen();
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
| `route(method, path, handler)` | Register any method |

### Quick Example

```zig
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

### Response Helpers

These methods allow fluent response chaining.

| Method | Description |
|--------|-------------|
| `status(code)` | Set HTTP status code |
| `setHeader(name, value)` | Set response header |
| `json(value)` | Send JSON response |
| `text(data)` | Send plain text |
| `html(data)` | Send HTML response |
| `file(path)` | Stream a file |
| `redirect(url, code)` | Send redirect |

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
