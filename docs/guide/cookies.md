# Cookies Guide

HTTPX handles cookies explicitly per request/response, following RFC 6265,
plus a standalone cookie jar utility (`httpx.CookieJar`).

## Client-Side Cookies

Pass cookies on individual requests with the `cookie` option:

```zig
const res = try client.get("https://example.com/api", .{
    .cookie = "theme=dark; lang=en",
});
defer res.deinit();
```

Read `Set-Cookie` values from any response with `res.header("Set-Cookie")`.

For multi-request flows, keep a `httpx.CookieJar` alongside the client:

```zig
var jar = httpx.CookieJar.init(allocator);
defer jar.deinit();

// After a login response carrying Set-Cookie:
if (loginRes.header("Set-Cookie")) |sc| {
    jar.setFromHeader(sc, "example.com");
}

// Before the next request, render the Cookie header.
// Pass secure=true when the connection uses TLS so Secure cookies are sent.
var cookieBuf: [512]u8 = undefined;
const cookieHeader = jar.cookieHeader("example.com", "/profile", true, &cookieBuf);
var profileRes = try client.get("https://example.com/profile", .{
    .cookie = cookieHeader,
});
defer profileRes.deinit();
```

## Server-Side Cookies

Read incoming cookies with `ctx.cookie(name)` and set them via `Set-Cookie`
response headers:

```zig
fn visitHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.cookie("session_token")) |token| {
        _ = token;
        return ctx.text("welcome back");
    }
    return .{
        .status = 200,
        .body = "{\"status\":\"cookie set\"}",
        .contentType = "application/json",
        .headers = &.{
            .{
                .name = "Set-Cookie",
                .value = "session_token=xyz123; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=86400",
            },
        },
    };
}
```

## Security Attributes

* **`Secure`**: Cookie is only sent over encrypted HTTPS connections.
* **`HttpOnly`**: Cookie cannot be accessed by client-side JavaScript (mitigates XSS token theft).
* **`SameSite=Strict`**: Cookie is never sent on cross-site requests, providing robust CSRF defense.

## Related

* [Security: Cookies](/security/cookies)
* [Example: Cookie Server](/examples/cookie-server)
