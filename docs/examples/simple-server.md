# Simple Server

Start a minimal server and return JSON from a single route.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn health(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .ok = true, .service = "demo" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_conflict = .increment,
        .max_port_tries = 32,
        .max_connections = 1000,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/health", health);
    try server.listen();
}
```

## Run

```bash
zig build run-all-simple_server
```

## What to Verify

- `GET /health` returns JSON response.
- Server starts without route registration errors.
- If `8080` is occupied, server startup can automatically move to the next port based on config.
- Browser request to `http://127.0.0.1:<effective-port>/health` returns immediately.
