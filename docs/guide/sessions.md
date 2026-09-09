# Session Management Guide

HTTPX has no built-in session store. The recommended pattern is cookie-backed
sessions in handlers — see `examples/session_server.zig` for a runnable
`/login`, `/dashboard`, `/logout` flow.

## Cookie-backed sessions

Issue a session cookie on login and read it back on later requests:

```zig
fn loginHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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

fn dashboardHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const session = ctx.cookie("session") orelse
        return ctx.textStatus(401, "login required");
    _ = session;
    return ctx.text("welcome back");
}

fn logoutHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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

The client keeps cookies automatically when `cookies: true` (the default) in
`ClientConfig`, and `ctx.cookie(name)` reads them server-side. For CSRF
protection on state-changing routes, use
`httpx.middleware.generateCsrfToken` / `verifyCsrfToken`.
