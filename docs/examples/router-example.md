# Router Example

Path parameters and multiple methods with route handlers.

```zig
const std = @import("std");
const httpx = @import("httpx");

fn getUser(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.param("id") orelse "unknown";
    return ctx.renderJson(.{ .id = id });
}

fn createUser(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.textStatus(201, "created");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{});
    defer server.deinit();

    try server.get("/users/{id}", getUser);
    try server.post("/users", createUser);
    server.run();
}
```

Routes support static segments, `{param}` parameters (via `ctx.param`),
and wildcards. See [Router](/api/router) and `examples/custom_server.zig`.

## Run

```bash
zig build run-custom-server
```

## What to Verify

- `GET /users/42` returns `id=42`.
- `POST /users` returns `201 created`.
