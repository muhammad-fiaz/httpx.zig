# Cookies Guide

HTTPX provides robust, secure cookie handling compliant with RFC 6265bis, including cookie jar management, `Set-Cookie` parsing, and security attributes.

## Client-Side Cookie Jar

The HTTPX client can manage cookies across requests automatically when enabled:

```zig
var client = httpx.Client.init(allocator, io, .{
    .cookies = true,
});
defer client.deinit();

// Login endpoint returns Set-Cookie: session_id=abc; Secure; HttpOnly
const login_res = try client.post("https://example.com/login", .{
    .json = .{ .user = "alice", .pass = "p@ssword" },
});
defer login_res.deinit();

// Next request automatically sends Cookie: session_id=abc
const profile_res = try client.get("https://example.com/profile", .{});
defer profile_res.deinit();
```

Alternatively, pass explicit cookies on individual requests:
```zig
const res = try client.get("https://example.com/api", .{
    .cookie = "theme=dark; lang=en",
});
defer res.deinit();
```

---

## Server-Side Cookies

On the server, inspect incoming cookies from `ctx` or set new ones:

```zig
server.get("/visit", struct {
    fn handle(ctx: *httpx.Context) !void {
        // Read cookie
        if (ctx.header("Cookie")) |cookie_hdr| {
            std.debug.print("Incoming Cookies: {s}\n", .{cookie_hdr});
        }

        // Set secure cookie
        ctx.header("Set-Cookie", "session_token=xyz123; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=86400");
        try ctx.json(.{ .status = "cookie set" });
    }
}.handle);
```

## Security Attributes

* **`Secure`**: Cookie is only sent over encrypted HTTPS connections.
* **`HttpOnly`**: Cookie cannot be accessed by client-side JavaScript (mitigates XSS token theft).
* **`SameSite=Strict`**: Cookie is never sent on cross-site requests, providing robust CSRF defense.

## Related

* [Security: Cookies](/security/cookies)
* [Example: Cookies Demo](/examples/cookies-demo)
