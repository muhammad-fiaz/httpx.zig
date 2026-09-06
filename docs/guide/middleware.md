# Middleware

Middleware functions execute before your route handlers. They can modify the request, response, or halt execution (e.g., for authentication).

## Using Middleware

To add global middleware to the server, use `server.use()`.

```zig
// Add standard logger
try server.use(httpx.middleware.logger());

// Add rate limiting
try server.use(httpx.middleware.rateLimit(.{
    .max_requests = 100,
    .window_ms = 60_000,
}));
```

Logging is opt-in. Use `httpx.middleware.loggerWithConfig(.{ .log_fn = ... })` to send logs to a custom sink, or omit the logger middleware to disable request logging.

## Built-in Middleware

`httpx.zig` includes:

- **Logger**: Logs request timing and status.
- **CORS**: Configures Cross-Origin Resource Sharing headers.
- **RateLimit**: Simple in-memory rate limiting (thread-safe with mutex).
- **BasicAuth**: RFC 7617 Basic Authentication.
- **Helmet**: Security headers (X-Content-Type-Options, X-Frame-Options, X-XSS-Protection, HSTS).
- **Compression**: Response compression middleware (gzip, deflate, br, zstd) via `httpx.middleware.compression()`. Compresses responses larger than 1KB by default, preferring brotli > zstd > gzip > deflate.
- **Timeout**: Application-level per-request timeout enforcement via `httpx.middleware.timeout(ms)`. Stores a deadline and returns 408 if exceeded.
- **RequestId**: Injects `X-Request-ID`.
- **BodyParser**: Validates Content-Length and body size against a maximum limit.
- **CSRF**: Double-submit cookie pattern for state-changing requests (POST/PUT/PATCH/DELETE).
- **Reverse Proxy**: Comptime and runtime reverse proxy with built-in SSRF protection (blocks private IPs).
- **Health Check**: Liveness probe middleware for Kubernetes deployments.
- **Readiness Probe**: Readiness probe middleware for Kubernetes deployments.

## Writing Custom Middleware

A middleware is simply a struct with a `handler` function. The handler receives the `Context` and a `next` function.

```zig
const MyMiddleware = struct {
    fn handler(ctx: *httpx.Context, next: httpx.server.middleware.Next) !httpx.Response {
        // 1. Pre-processing
        if (ctx.header("X-Ban")) |_| {
            return ctx.status(403).text("Banned");
        }

        // 2. Call next in chain
        const response = try next(ctx);

        // 3. Post-processing (optional)
        // e.g., inspect response.status

        return response;
    }
};

try server.use(.{ 
    .name = "ban_check", 
    .handler = MyMiddleware.handler 
});
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
