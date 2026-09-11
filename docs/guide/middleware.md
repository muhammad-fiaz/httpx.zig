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
- **`httpx.middleware.helmet`**: Defensive headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Content-Security-Policy`).
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

## Scopes and Ordering

Middleware runs in a deterministic order: router-wide (`server.use`)
first, then route-level (`.{ .middleware = ... }` on registration),
then the handler. Groups prepend their middleware to each route:

```zig
const api = server.router.group("/api", .{ .middleware = &.{authMw} });
try api.get("/users", listUsers, .{ .middleware = &.{auditMw} });
// order: server.use middlewares → authMw → auditMw → listUsers
```

## Compression

Response compression is available through the `httpx.compression` codec
(gzip, deflate, brotli, zstd) applied inside handlers. There is no built-in
compression middleware; negotiate `Accept-Encoding` in the handler and encode
the body explicitly.

## Rate Limiting

Use `httpx.RateLimiter` for per-key request-rate enforcement (see
`src/web/middleware/rate_limit.zig` for `RateLimitPolicy`,
`RateLimitResult`, and `RateLimitDimension`).

## CSRF Helpers

Use `httpx.middleware.generateCsrfToken` / `httpx.middleware.verifyCsrfToken`
(double-submit cookie pattern) inside handlers for state-changing routes.
There is no built-in CSRF middleware; GET/HEAD/OPTIONS pass through
unchallenged by construction.
