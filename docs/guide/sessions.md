# Session Management Guide

HTTPX has no built-in session store. The recommended pattern is cookie-backed
sessions in handlers; see `examples/sessionServer.zig` for a runnable
`/login`, `/dashboard`, `/logout` flow.

## Cookie-backed sessions

Issue a session cookie on login and read it back on later requests:

```zig
fn loginHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    _ = ctx;
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged in\"}",
        .contentType = "application/json",
        .headers = &.{
            .{ .name = "Set-Cookie", .value = "session=abc123; Path=/; HttpOnly" },
        },
    };
}

fn dashboardHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const session = ctx.cookie("session") orelse
        return ctx.textStatus(401, "login required");
    _ = session;
    return ctx.text("welcome back");
}

fn logoutHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    _ = ctx;
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged out\"}",
        .contentType = "application/json",
        .headers = &.{
            .{ .name = "Set-Cookie", .value = "session=; Path=/; Max-Age=0" },
        },
    };
}
```

## Client behavior

The client does not retain cookies automatically. Send the session cookie on
each request with `.cookie`, or keep it in the standalone
`httpx.client.cookieJar`. Server handlers read it with `ctx.cookie(name)`.

For CSRF protection on state-changing routes, install
`httpx.middleware.csrf` rather than calling token helpers directly. See
[API: Middleware](/api/middleware#csrf-middleware).
