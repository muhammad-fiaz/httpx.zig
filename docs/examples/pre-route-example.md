# Pre-Route Hook and Global Fallback Example

Demonstrates `server.preRoute()` for hooks that run before route matching, and `server.global()` for fallback handlers on unmatched routes.

## Features Covered

- **Pre-Route Hooks**: Run setup/logging before every request via `server.preRoute(fn)`. Pre-route hooks return `anyerror!void` — they cannot reject requests. For auth gating, use middleware instead.
- **Global Fallback**: `server.global(fn)` handles requests that don't match any registered route.
- **JSON Responses**: Returning structured JSON from handlers.

## Demo Program

```zig
// Pre-route hook — runs before route matching
fn preRouteHook(ctx: *httpx.Context) anyerror!void {
    const method = @tagName(ctx.request.method);
    const path = ctx.request.uri.path;
    std.debug.print("[preRoute] {s} {s}\n", .{ method, path });
}

// Global fallback for unmatched routes
fn notFoundHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.status(404).json(.{
        .@"error" = "Not Found",
        .path = ctx.request.uri.path,
    });
}

var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 0,
});
defer server.deinit();

// Register pre-route hook — runs before route matching
try server.preRoute(preRouteHook);

// Register global fallback for unmatched routes
server.global(notFoundHandler);

// Register routes
try server.get("/", homeHandler);
try server.get("/api/users", apiUsersHandler);
```

## Run

```
zig build run-all-pre_route_example
```

## Expected Output

```
[preRoute] GET /
Status: 200, Body: Welcome home!

[preRoute] GET /api/users
Status: 200, Body: {"users":["alice","bob"]}

[preRoute] GET /nonexistent
Status: 404, Body: {"error":"Not Found","path":"/nonexistent"}
```
