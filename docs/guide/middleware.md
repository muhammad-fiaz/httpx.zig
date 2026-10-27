# Middleware

Middleware functions execute before your route handlers. They can modify the request, response, or halt execution (e.g., for authentication).

## Using Middleware

To add global middleware to the server, use `server.use()`. Middleware functions follow the signature `fn (*httpx.router.Context, httpx.router.NextFn) anyerror!httpx.router.Response`.

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
- **`httpx.middleware.logging`**: Pass-through compatibility hook; use the server `logging.callback` for structured request events.
- **`httpx.middleware.csrf`**: Double-submit cookie CSRF protection. Safe methods receive a token cookie when absent; state-changing requests must echo the token in the `X-CSRF-Token` header or receive `403 Forbidden`.
- **`httpx.RateLimiter`**: Multi-dimensional token bucket rate limiting (by IP, Bearer token, route, or custom key).
- **`httpx.middleware.generateCsrfToken` / `verifyCsrfToken`**: Low-level helpers. `generateCsrfToken` is test-only; production code should use the middleware, which draws tokens from OS entropy.

## Writing Custom Middleware

A custom middleware is a function that receives the `*httpx.router.Context` and the `NextFn` callback:

```zig
fn banCheckMiddleware(ctx: *httpx.router.Context, next: httpx.router.NextFn) anyerror!httpx.router.Response {
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

The server compresses handler responses automatically for HTTP/1.1, HTTP/2,
and HTTP/3. It parses `Accept-Encoding`, selects `zstd`, `br`, `gzip`, or
`deflate`, and sends `Content-Encoding` plus `Vary: Accept-Encoding` only when
the coded body is smaller. Negotiation is driven by `.compression` in the
options passed to `httpx.Server.init`; bodies larger than `.maxCompressionInput`
(128 KiB by default) are sent unchanged. Unsupported or forbidden encodings
produce `406 Not Acceptable`.

The `httpx.compression` codec remains available when a handler needs explicit
control over compression.

## Rate Limiting

Use `httpx.RateLimiter` for per-key request-rate enforcement (see
`src/web/middleware/rateLimiter.zig` for `RateLimitPolicy`,
`RateLimitResult`, and `RateLimitDimension`).

## CSRF Protection

Register the built-in middleware globally:

```zig
try server.use(httpx.middleware.csrf);
```

Safe methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) pass through and receive a
`csrf_token` cookie when one is not already present. `POST`, `PUT`, `PATCH`,
`DELETE`, and other state-changing methods compare the cookie with the
`X-CSRF-Token` header using a constant-time check, returning `403 Forbidden`
when either value is missing or they differ.

Use `httpx.middleware.verifyCsrfToken` for a constant-time comparison in
custom policies. Avoid `generateCsrfToken` in production: it accepts a
caller-supplied PRNG and exists for tests. The built-in middleware defines safe
cookie name, header name, path, `SameSite`, and `Secure` defaults configured via `.{}`.
