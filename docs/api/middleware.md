# Middleware API

Middleware functions sit between the incoming request and your route handlers. They are useful for logging, authentication, CORS, security headers, recovery, and rate limiting.

## Usage

Global middleware is added using `server.use()` with a plain middleware
function value:

```zig
try server.use(httpx.middleware.cors);
try server.use(httpx.middleware.helmet);
try server.use(httpx.middleware.recovery);
try server.use(httpx.middleware.logging);
```

The same values are also reachable under `httpx.web.middleware`
(`cors`, `securityHeaders`, `recovery`, `logging`, `RateLimiter`).

## Built-in Middleware

### `cors`

Handles Cross-Origin Resource Sharing (CORS) headers and `OPTIONS` preflight
with a permissive default policy (`*` origin).

```zig
try server.use(httpx.middleware.cors);
```

- Handles preflight `OPTIONS` requests with `204 No Content`.
- Appends `Access-Control-Allow-Origin: *` to normal responses.

For origin/method allow-list checks in custom handlers, use
`httpx.middleware.CorsConfig` directly:

```zig
const cfg = httpx.middleware.CorsConfig{
    .allowedOrigins = &.{ "https://example.com" },
    .allowedMethods = &.{ "GET", "POST" },
    .allowedHeaders = &.{ "Content-Type", "Authorization" },
    .exposedHeaders = &.{ "X-Request-ID" },
    .allowCredentials = true,
    .maxAgeSeconds = 86400,
};
if (!cfg.isOriginAllowed(origin)) return error.Forbidden;
```

### `helmet` / `securityHeaders`

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
fn onEvent(event: httpx.ServerEvent) void {
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
`src/web/middleware/rate_limit.zig` for `RateLimitPolicy`,
`RateLimitResult`, and `RateLimitDimension`).

## Creating Custom Middleware

A middleware is a function taking the request context plus the next handler:

```zig
fn timing(ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response {
    const t0 = std.time.nanoTimestamp();
    const resp = try next(ctx);
    const elapsedMs = @divTrunc(std.time.nanoTimestamp() - t0, 1_000_000);
    std.debug.print("{s} {s} - {d}ms\n", .{ @tagName(ctx.method), ctx.path, elapsedMs });
    return resp;
}

try server.use(timing);
```
