# Session Example

Cookie-backed sessions in handlers. See `examples/session_server.zig` for a
runnable `/login`, `/dashboard`, `/logout` flow.

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
```

There is no built-in session store; keep server-side state in your own
structures keyed by the session cookie value.

## Run

```bash
zig build run-session-server
```

## What to Verify

- `GET /login` returns 200.
- `GET /dashboard` without a session returns 401.
