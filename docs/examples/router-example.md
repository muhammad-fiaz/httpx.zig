# Router Example

Use path parameters and multiple methods with route handlers.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn getUser(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.param("id") orelse "unknown";
    return ctx.json(.{ .id = id });
}

fn createUser(ctx: *httpx.Context) anyerror!httpx.Response {
    return httpx.Response.fromText(ctx.allocator, 201, "created");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/users/:id", getUser);
    try server.post("/users", createUser);
    try server.listen();
}
```

## Run

```bash
zig build run-all-router_example
```

## What to Verify

- `GET /users/42` returns `id=42`.
- `POST /users` returns `201 created`.
