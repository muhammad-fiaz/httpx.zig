# Cookies Demo

Cookie flows with per-request headers and the standalone `httpx.client.CookieJar`.
See `examples/cookieServer.zig`.

```zig
var jar = httpx.client.CookieJar.init(allocator, io);
defer jar.deinit();

// Store a Set-Cookie value received from a login response.
if (loginRes.header("Set-Cookie")) |sc| {
    jar.setFromHeader(sc, "example.com");
}

// Render the Cookie header for the next request (secure=true over TLS).
var cookieBuf: [512]u8 = undefined;
const cookieHeader = jar.cookieHeader("example.com", "/profile", true, &cookieBuf);
var profileRes = try client.get("https://example.com/profile", .{ .cookie = cookieHeader });
defer profileRes.deinit();

// Server side: read cookies with ctx.cookie(name).
```

## Expected Output

```text
Cookie server running on http://127.0.0.1:54321
GET /get -> status=200, body={"username":"anonymous"}
Cookie server verification completed successfully.
```

The port is ephemeral so it varies on every run; the body shows the representative JSON payload for the requested cookie state.

## Run

```bash
zig build run-cookie-server
```

## What to Verify

- `GET /get` returns 200 with the expected JSON body.
- Jar round-trips survive domain/path/expiry checks.
