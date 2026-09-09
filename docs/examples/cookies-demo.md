# Cookies Demo

Cookie flows with per-request headers and the standalone `httpx.CookieJar`.
See `examples/cookie_server.zig`.

```zig
var jar = httpx.CookieJar.init(allocator);
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

## Run

```bash
zig build run-cookie-server
```

## What to Verify

- `GET /get` returns 200 with the expected JSON body.
- Jar round-trips survive domain/path/expiry checks.
