# Middleware Example

Chain middleware for logging, CORS, and custom request checks.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn auth(ctx: *httpx.Context, next: httpx.Next) anyerror!httpx.Response {
    if (ctx.header("Authorization") == null) {
        return ctx.status(401).json(.{ .error = "missing auth" });
    }
    return next(ctx);
}

fn secure(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .message = "secure route" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.use(httpx.logger());
    try server.use(httpx.cors(.{}));
    try server.use(.{ .name = "auth", .handler = auth });

    try server.get("/secure", secure);
    try server.listen();
}
```

## Run

```bash
zig build run-middleware_example
```

## What to Verify

- Requests without auth header return 401.
- Requests with auth header reach final handler.
