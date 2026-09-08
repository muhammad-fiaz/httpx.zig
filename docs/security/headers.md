# Security Headers

HTTP security headers instruct modern web browsers to activate built-in defenses against clickjacking, MIME sniffing, cross-site scripting, and man-in-the-middle attacks.

## Recommended Standard Headers

| Header | Recommended Value | Protection |
|---|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains; preload` | Enforces HTTPS exclusively for 1 year |
| `X-Content-Type-Options` | `nosniff` | Disables MIME type sniffing |
| `X-Frame-Options` | `DENY` | Prevents framing and clickjacking |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Protects sensitive URL paths from referrers |
| `Content-Security-Policy` | `default-src 'self'` | Restricts sources of executable scripts/styles |

## Server Implementation

```zig
fn securityHeadersMiddleware(ctx: *httpx.Context) !void {
    ctx.header("Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload");
    ctx.header("X-Content-Type-Options", "nosniff");
    ctx.header("X-Frame-Options", "DENY");
    ctx.header("Referrer-Policy", "strict-origin-when-cross-origin");
    ctx.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
    try ctx.next();
}
```

## Related

* [Security: Overview](/security/overview)
* [Example: Helmet Server](/examples/helmet-server)
