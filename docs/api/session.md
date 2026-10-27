# Session API

HTTPX has no built-in server-side session store. The recommended pattern is
cookie-backed sessions in handlers; see `examples/sessionServer.zig` for a
runnable `/login`, `/dashboard`, `/logout` flow.

To persist a session across requests, issue a cookie on login and read it
back on later requests:

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
```

The client does not retain cookies automatically. Send the session cookie on
each request with `.cookie`, or keep it in the standalone
`httpx.client.cookieJar`. Server handlers read it with `ctx.cookie(name)`.

For CSRF protection on state-changing routes, install
`httpx.middleware.csrf`; the token helpers are lower-level utilities. See
[API: Middleware](/api/middleware#csrf-middleware).
