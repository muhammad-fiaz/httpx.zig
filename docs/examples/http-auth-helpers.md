# HTTP Auth Helpers

Use built-in authentication helpers for Bearer and Basic authorization.

This demo runs fully on local loopback so it is deterministic and does not require internet access.
It starts a local server, performs Bearer and Basic checks, and exits cleanly.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn bearerHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const token = ctx.bearerToken() orelse {
        return ctx.status(401).json(.{ .error = "missing bearer token" });
    };

    if (!std.mem.eql(u8, token, "demo-token")) {
        return ctx.status(401).json(.{ .error = "invalid bearer token" });
    }

    return ctx.json(.{ .kind = "bearer", .ok = true });
}

fn basicHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const auth = ctx.authorization() orelse {
        return ctx.status(401).json(.{ .error = "missing basic auth" });
    };

    if (!std.mem.eql(u8, auth, "Basic ZGVtbzpwYXNz")) {
        return ctx.status(401).json(.{ .error = "invalid basic credentials" });
    }

    return ctx.json(.{ .kind = "basic", .ok = true });
}

pub fn main() !void {
    // Full runnable source: examples/http_auth_helpers.zig
    // Request-side helpers used in this demo:
    // - RequestOptions.withBearerToken("demo-token")
    // - RequestOptions.withBasicAuth("demo", "pass")
    // - Request.setBearerAuth("demo-token")
    // - Request.setBasicAuth("demo", "pass")
}
```

## Run

```bash
zig build run-all-http_auth_helpers
```

## What to Verify

- Bearer request returns HTTP 200 with JSON response.
- Basic request returns HTTP 200 with JSON response.
- Manual `Request.setBearerAuth(...)` writes `Authorization: Bearer ...`.
