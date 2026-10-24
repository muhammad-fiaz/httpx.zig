# Router Example

Path parameters and multiple methods with route handlers.

```zig
const std = @import("std");
const httpx = @import("httpx");

fn getUser(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const id = ctx.param("id") orelse "unknown";
    return ctx.renderJson(.{ .id = id });
}

fn createUser(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.textStatus(201, "created");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{});
    defer server.deinit();

    try server.get("/users/{id}", getUser);
    try server.post("/users", createUser);
    server.run();
}
```

Routes support static segments, `{param}` parameters (via `ctx.param`),
and wildcards. See [Router](/api/router) and `examples/customServer.zig`.

## Expected Output

The snippet itself prints nothing; a client exchange against it looks like
(representative values shown):

```text
GET /users/42 -> status=200 body={"id":"42"}
POST /users -> status=201 body=created
```

Statuses, bodies, and ids vary with the request path and handler logic.

## Run

```bash
zig build run-custom-server
```

## What to Verify

- `GET /users/42` returns `id=42`.
- `POST /users` returns `201 created`.
