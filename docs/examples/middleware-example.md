# Middleware Example

Chain middleware for CORS, headers, recovery, and custom request checks.

```zig
const std = @import("std");
const httpx = @import("httpx");

fn auth(ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response {
    if (ctx.header("Authorization") == null) {
        return ctx.textStatus(401, "missing auth");
    }
    return next(ctx);
}

fn secure(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .message = "secure route" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{});
    defer server.deinit();

    try server.use(httpx.middleware.logging);
    try server.use(httpx.middleware.cors);
    try server.use(httpx.middleware.helmet);
    try server.use(auth);

    try server.get("/secure", secure);
    server.run();
}
```

Built-ins: `cors`, `helmet`, `recovery`, `logging`,
plus `RateLimiter` and CSRF token helpers. See [Middleware](/api/middleware).

## Run

```bash
zig build run-helmet-server
```

## What to Verify

- Unauthenticated requests return 401.
- Security headers appear on responses.
