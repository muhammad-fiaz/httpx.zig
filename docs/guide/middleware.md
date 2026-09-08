# Middleware

Middleware functions execute before your route handlers. They can modify the request, response, or halt execution (e.g., for authentication).

## Using Middleware

To add global middleware to the server, use `server.use()`. Middleware functions follow the signature `fn (*httpx.Context, httpx.router.NextFn) anyerror!httpx.Response`.

```zig
// Add standard CORS middleware
try server.use(httpx.middleware.cors);

// Add security headers (Helmet)
try server.use(httpx.middleware.helmet);

// Add error recovery (500 fallback)
try server.use(httpx.middleware.recovery);
```

## Built-in Middleware

`httpx.zig` includes built-in middleware under the `httpx.middleware` namespace:

- **`httpx.middleware.cors`**: Handles preflight `OPTIONS` requests (204 No Content) and injects CORS response headers.
- **`httpx.middleware.helmet` / `httpx.middleware.securityHeaders`**: Defensive headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Content-Security-Policy`).
- **`httpx.middleware.recovery`**: Intercepts uncaught handler errors and returns safe HTTP 500 responses without crashing the connection loop.
- **`httpx.middleware.logging`**: Non-blocking request pass-through and observability hooks.
- **`httpx.RateLimiter`**: Multi-dimensional token bucket rate limiting (by IP, Bearer token, route, or custom key).
- **`httpx.middleware.generateCsrfToken` / `verifyCsrfToken`**: Double-submit cookie CSRF validation.

## Writing Custom Middleware

A custom middleware is a function that receives the `*httpx.Context` and the `NextFn` callback:

```zig
fn banCheckMiddleware(ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response {
    // 1. Pre-processing
    if (ctx.header("X-Ban")) |_| {
        return ctx.textStatus(403, "Forbidden");
    }

    // 2. Call next in chain
    var response = try next(ctx);

    // 3. Post-processing (optional)
    // Modify response or inspect response.status
    return response;
}

try server.use(banCheckMiddleware);
```

## Compression Middleware

Use `httpx.middleware.compression()` to enable automatic response compression. The middleware negotiates the best encoding based on the client's `Accept-Encoding` header and compresses the response body before sending.

```zig
try server.use(httpx.middleware.compression());
```

This enables gzip, deflate, brotli, and zstd compression. The middleware:
- Reads the incoming `Accept-Encoding` header
- Prefers brotli > zstd > gzip > deflate (first match wins)
- Only compresses when the response body exceeds `min_bytes` (default: 1024)
- Skips compression if `Content-Encoding` is already set on the response

With explicit configuration:

```zig
try server.use(httpx.middleware.compressionMiddlewareWithConfig(.{
    .min_bytes = 512, // compress responses >= 512 bytes
}));
```

## Timeout Middleware

Use `httpx.middleware.timeout(ms)` to enforce a per-request timeout at the application level. This complements the server's `request_timeout_ms` socket-level timeout:

```zig
try server.use(httpx.middleware.timeout(5_000)); // 5 second timeout
```

If the deadline has passed before the handler runs, returns `408 Request Timeout` immediately.

## CSRF Protection

Use `httpx.csrf(.{})` to protect state-changing requests from cross-site request forgery:

```zig
try server.use(httpx.csrf(.{}));
```

The middleware uses the double-submit cookie pattern:
1. On the first POST/PUT/PATCH/DELETE request, generates a random token and sets it as a cookie.
2. Subsequent requests must include the token in the `X-CSRF-Token` header or `_csrf` form field.
3. GET/HEAD/OPTIONS requests are not challenged.

## SSRF Protection in Reverse Proxy

The `reverseProxy` and `reverseProxyRuntime` middlewares include built-in SSRF protection that blocks requests targeting private/internal IP ranges:

- `localhost`, `0.0.0.0`, `127.0.0.1`, `::1`
- `127.0.0.0/8` (loopback)
- `10.0.0.0/8` (private Class A)
- `172.16.0.0/12` (private Class B)
- `192.168.0.0/16` (private Class C)
- `169.254.0.0/16` (link-local)
- `198.18.0.0/15` (benchmarking)

Blocked requests return `403 Forbidden`.
