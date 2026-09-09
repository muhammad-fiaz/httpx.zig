# HTTP Auth Helpers

Bearer and Basic auth on both sides of the wire. See
`examples/auth_and_errors.zig`.

```zig
// Server side: read credentials from the context.
fn bearerHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const token = ctx.bearerToken() orelse {
        return ctx.textStatus(401, "missing bearer token");
    };
    if (!std.mem.eql(u8, token, "demo-token")) {
        return ctx.textStatus(401, "invalid bearer token");
    }
    return ctx.renderJson(.{ .kind = "bearer", .ok = true });
}

fn basicHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const auth = ctx.basicAuth() orelse {
        return ctx.textStatus(401, "missing basic auth");
    };
    if (!std.mem.eql(u8, auth.username, "demo")) {
        return ctx.textStatus(401, "invalid basic credentials");
    }
    return ctx.renderJson(.{ .kind = "basic", .ok = true });
}
```

```zig
// Client side: per-request auth helpers.
var res = try client.get("https://api.example.com/protected", .{
    .bearerAuth = "demo-token",
});
defer res.deinit();

var admin = try client.get("https://api.example.com/admin", .{
    .basicAuth = "demo:pass",
});
defer admin.deinit();
```

## Run

```bash
zig build run-auth-and-errors
```

## What to Verify

- Missing bearer token returns 401; valid token returns 200.
- Basic auth round-trips through `ctx.basicAuth()`.
