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
ctx.header(
    "Set-Cookie",
    "session_id=s_94f83b281a; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=3600",
);
```

## Client-Side Security

When the client is configured with `.cookies = true`:
1. Cookies marked `Secure` are discarded if received over plain HTTP.
2. Cookies are strictly partitioned by effective domain name and path.
3. Supercookies or cross-domain cookies matching public suffixes are rejected.

## Related

* [Guide: Cookies](/guide/cookies)
* [Security: Overview](/security/overview)
