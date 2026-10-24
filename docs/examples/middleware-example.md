# Middleware Example

Chain middleware for CORS, headers, recovery, and custom request checks.

```zig
const std = @import("std");
const httpx = @import("httpx");

fn auth(ctx: *httpx.web.router.Context, next: httpx.web.router.NextFn) anyerror!httpx.web.router.Response {
    if (ctx.header("Authorization") == null) {
        return ctx.textStatus(401, "missing auth");
    }
    return next(ctx);
}

fn secure(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.renderJson(.{ .message = "secure route" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{});
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

## Expected Output

When run via the helmet server target, the output follows that program's print format:

```text
Secure server running on http://127.0.0.1:54321
GET / -> status=200, body={"message":"Security headers enabled"}
Helmet server verification completed successfully.
```

The port number varies per run; unauthenticated requests against the `auth` snippet above return `401` with the `"missing auth"` body instead of `200`.

## Run

```bash
zig build run-helmet-server
```

## What to Verify

- Unauthenticated requests return 401.
- Security headers appear on responses.
