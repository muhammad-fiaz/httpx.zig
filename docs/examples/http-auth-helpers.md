# HTTP Auth Helpers

Bearer and Basic auth on both sides of the wire. See
`examples/authAndErrors.zig`.

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

## Expected Output

```text
=== Custom Error & Auth Security Validation ===
1. Custom 404 Response Status: 404
   Contains Custom HTML: true
2. Custom 500 Response Status: 500
   Contains JSON Error: true
3. Missing Bearer Token Status: 401
4. Valid Bearer Token Status: 200
   Protected Payload: {"role":"admin","secretCode":"ALPHA-OMEGA-99"}
5. Valid Basic Auth Status: 200
   Protected Payload: {"role":"manager","secretCode":"BETA-KAPPA-42"}
Custom Error Pages, 404 Fallback & Auth validation completed successfully.
```

Status codes are fixed per scenario (404/500/401/200); payload values reflect the demo credentials and server port varies per run.

## Run

```bash
zig build run-auth-and-errors
```

## What to Verify

- Missing bearer token returns 401; valid token returns 200.
- Basic auth round-trips through `ctx.basicAuth()`.
