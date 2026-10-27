# Middleware API

Middleware functions sit between the incoming request and your route handlers. They are useful for CORS, security headers, recovery, CSRF protection, and rate limiting.

## Usage

Global middleware is added using `server.use()` with a plain middleware
function value:

```zig
try server.use(httpx.middleware.cors);
try server.use(httpx.middleware.helmet);
try server.use(httpx.middleware.csrf);
try server.use(httpx.middleware.recovery);
try server.use(httpx.middleware.logging);
```

The same values are also reachable under `httpx.web.middleware`
(`cors`, `helmet`, `recovery`, `logging`, `RateLimiter`).

## Built-in Middleware

### `cors`

Handles Cross-Origin Resource Sharing (CORS) headers and `OPTIONS` preflight
with a permissive default policy (`*` origin).

```zig
try server.use(httpx.middleware.cors);
```

- Handles preflight `OPTIONS` requests with `204 No Content`.
- Appends `Access-Control-Allow-Origin: *` to normal responses.

The built-in middleware uses a permissive `*` policy and takes no
configuration. For exact-origin or method allow-lists, implement a custom
middleware that validates the `Origin` header; `CorsConfig` exists only as an
internal policy helper in `src/web/middleware/securityHeaders.zig`.

### `helmet`

Adds defensive security headers (`X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, `Content-Security-Policy`).

```zig
try server.use(httpx.middleware.helmet);
```

### `recovery`

Catches uncaught handler errors and returns a `500` response without panicking.

```zig
try server.use(httpx.middleware.recovery);
```

### `logging`

Request logging hook (currently a pass-through; application event logging
belongs in the server `logging.callback`).

```zig
try server.use(httpx.middleware.logging);
```

For structured server events, configure the server itself:

```zig
fn onEvent(event: httpx.logging.ServerEvent) void {
    std.debug.print("{s} {s} {d} {d}ms\n", .{
        event.method, event.path, event.status, event.durationMs,
    });
}

var server = try httpx.Server.init(allocator, io, .{
    .logging = .{ .callback = onEvent },
});
```

### `RateLimiter`

Token-bucket style per-key rate limiting (see
`src/web/middleware/rateLimiter.zig` for `RateLimitPolicy`,
`RateLimitResult`, and `RateLimitDimension`).

### `csrf`

Double-submit cookie CSRF protection.

```zig
try server.use(httpx.middleware.csrf);
```

Safe methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) pass through and set a
`csrf_token` cookie when absent. Other methods require the cookie value in
the `X-CSRF-Token` header; missing or mismatched tokens return `403 Forbidden`.
`httpx.middleware.verifyCsrfToken` performs the constant-time comparison.
`httpx.middleware.generateCsrfToken` is test-only because it accepts a
caller-supplied PRNG; production code should use the middleware, which mints
tokens from OS entropy. Standard cookie and header configurations support defaults using `.{}`.

## Creating Custom Middleware

A middleware is a function taking the request context plus the next handler:

```zig
fn timing(ctx: *httpx.router.Context, next: httpx.router.NextFn) anyerror!httpx.router.Response {
    const t0 = std.time.nanoTimestamp();
    const resp = try next(ctx);
    const elapsedMs = @divTrunc(std.time.nanoTimestamp() - t0, 1_000_000);
    std.debug.print("{s} {s} - {d}ms\n", .{ @tagName(ctx.method), ctx.path, elapsedMs });
    return resp;
}

try server.use(timing);
```
