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
// Adds X-Content-Type-Options, X-Frame-Options, Referrer-Policy,
// and Content-Security-Policy.
try server.use(httpx.middleware.helmet);
```

`helmet` does not set `Strict-Transport-Security` or `Permissions-Policy`.
Add those in a response middleware or on the routes that need them.

## Related

* [Security: Overview](/security/overview)
* [Example: Helmet Server](/examples/helmet-server)
