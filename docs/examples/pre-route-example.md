# Pre-Route Logic and Global Fallback Example

There is no `server.preRoute()` hook: logic that runs before route matching
belongs in middleware. Unmatched routes fall back to 404, customizable with
`setNotFoundHandler`.

```zig
fn accessLog(ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response {
    std.debug.print("[request] {s} {s}\n", .{ @tagName(ctx.method), ctx.path });
    return next(ctx);
}

fn notFound(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.textStatus(404, "Not Found");
}

var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
});
defer server.deinit();

try server.use(accessLog);
try server.get("/hello", helloHandler);
server.router.setNotFoundHandler(notFound);
```

## What to Verify

- Every request passes through the middleware first.
- Unknown paths return the custom 404 body.
