# Cookie Security

HTTPX implements the latest RFC 6265bis specifications, providing defense-in-depth protections against Cross-Site Scripting (XSS) and Cross-Site Request Forgery (CSRF).

## Security Attributes

* **`Secure`**: Enforces that the cookie is transmitted only over encrypted TLS/HTTPS connections. Prevents cleartext packet sniffing.
* **`HttpOnly`**: Blocks client-side scripts (e.g. `document.cookie`) from reading the cookie, mitigating session hijacking via XSS vulnerabilities.
* **`SameSite=Strict`**: Completely prohibits the browser from sending the cookie on cross-site requests (including standard incoming links).
* **`SameSite=Lax`**: Prohibits sending cookies on cross-site subrequests (images, iframes, POST submissions), while allowing top-level GET navigations.

## Server-Side Configuration

```zig
// Setting a hardened session cookie in server handlers
return .{
    .status = 200,
    .body = "{\"status\":\"cookie set\"}",
    .contentType = "application/json",
    .headers = &.{
        .{
            .name = "Set-Cookie",
            .value = "session_id=s_94f83b281a; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=3600",
        },
    },
};
```

## Client-Side Security

The standalone `httpx.CookieJar` partitions by domain and path:

1. Cookies marked `Secure` are only emitted when the caller passes `secure = true` (TLS).
2. Cookies are strictly partitioned by effective domain name and path.
3. Expired cookies are skipped (and dropped by `purgeExpired`).

## Related

* [Guide: Cookies](/guide/cookies)
* [Security: Overview](/security/overview)
