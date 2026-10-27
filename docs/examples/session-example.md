# Session Example

Cookie-backed sessions in handlers. See `examples/sessionServer.zig` for a
runnable `/login`, `/dashboard`, `/logout` flow.

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

There is no built-in session store; keep server-side state in your own
structures keyed by the session cookie value.

## Expected Output

The handlers print nothing themselves; `examples/sessionServer.zig`
verifies them with lines in this format (representative values shown):

```text
Session server running on http://127.0.0.1:41237
GET /login -> status=200, body={"message":"Logged in","user":"alice"}
Session server verification completed successfully.
```

Statuses, bodies, URLs, and ports vary with the request and the ephemeral port selected at runtime.

## Run

```bash
zig build run-session-server
```

## What to Verify

- `GET /login` returns 200.
- `GET /dashboard` without a session returns 401.
