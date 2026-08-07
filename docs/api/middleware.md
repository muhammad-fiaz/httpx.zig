# Middleware API

Middleware functions sit between the incoming request and your route handlers. They are useful for logging, authentication, CORS, compression, health probes, and more.

## Usage

Global middleware is added using `server.use()`.

```zig
try server.use(httpx.middleware.logger());
try server.use(httpx.middleware.cors(.{}));
```

## Built-in Middleware

All middleware is in the `httpx.middleware` namespace.

### `logger`

Logs request method, path, and timing to `std.debug` by default.

```zig
server.use(httpx.middleware.logger());
```

To route logs to a custom sink:

```zig
server.use(httpx.middleware.loggerWithConfig(.{
    .log_fn = myLogFn,
}));
```

### `cors`

Handles Cross-Origin Resource Sharing (CORS) headers and `OPTIONS` preflight.
All method and header strings are computed at **comptime**, so there are
**zero heap allocations** per request.

```zig
server.use(httpx.middleware.cors(.{
    .allowed_origins = &[_][]const u8{"https://example.com"},
    .allowed_methods = &[_]Method{.GET, .POST},
    .allowed_headers = &[_][]const u8{"Content-Type", "Authorization"},
    .exposed_headers = &[_][]const u8{"X-Request-ID"},
    .allow_credentials = true,
    .max_age = 86400,
}));
```

- Sets `Access-Control-Allow-Origin` with origin-aware matching.
- Handles preflight `OPTIONS` requests with `204 No Content`.
- Sets `Access-Control-Allow-Credentials` when `allow_credentials = true`.
- All header values are comptime-constant strings (no per-request allocation).

### `rateLimit`

In-memory rate limiting per client IP. Stale entries are automatically
evicted every 512 requests to prevent unbounded memory growth.

```zig
server.use(httpx.middleware.rateLimit(.{
    .max_requests = 100,
    .window_ms = 60_000,
}));
```

| Field | Default | Description |
|-------|---------|-------------|
| `max_requests` | `100` | Max requests per window per IP |
| `window_ms` | `60000` | Rolling window duration in milliseconds |

### `basicAuth`

HTTP Basic Authentication with a user-supplied validator.

```zig
fn validate(user: []const u8, pass: []const u8) bool {
    return std.mem.eql(u8, user, "admin") and std.mem.eql(u8, pass, "secret");
}

server.use(httpx.middleware.basicAuth("My Realm", validate));
```

### `helmet`

Adds security headers: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Strict-Transport-Security`, and `Referrer-Policy`.

```zig
server.use(httpx.middleware.helmet());
```

### `compression`

Compresses response bodies based on the client's `Accept-Encoding` header.
Supports gzip, deflate, brotli, and zstd. Only compresses when the response
body exceeds the minimum size threshold (default: 1024 bytes) and no
`Content-Encoding` header is already set.

```zig
server.use(httpx.middleware.compression());
```

With explicit configuration:

```zig
server.use(httpx.middleware.compressionMiddlewareWithConfig(.{
    .min_bytes = 512, // compress responses >= 512 bytes
}));
```

### `requestId`

Generates and attaches a unique `X-Request-ID` header to every request.

```zig
server.use(httpx.middleware.requestId());
```

### `timeout`

Applies a per-request timeout. Stores a deadline in the context and checks
it before calling the next handler. If the deadline has already passed,
returns `408 Request Timeout`. The server's `request_timeout_ms` config
provides primary timeout enforcement at the socket level; this middleware
provides application-level checking for slow downstream handlers.

```zig
server.use(httpx.middleware.timeout(5_000)); // 5 seconds
```

### `bodyParser`

Parses request body based on `Content-Type` (JSON, form-urlencoded).

```zig
server.use(httpx.middleware.bodyParser());
```

### `healthCheck`

Intercepts requests to a configured path and returns a health status response. Useful for Kubernetes liveness probes.

```zig
server.use(httpx.middleware.healthCheck(.{
    .path = "/health",
    .body = "{\"status\":\"ok\"}",
    .status = 200,
}));
```

`HealthConfig` fields:

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"/health"` | Path to intercept |
| `body` | `"{\"status\":\"ok\"}"` | Response body |
| `status` | `200` | HTTP status code |

### `readinessProbe`

Intercepts requests to a configured readiness path. Useful for Kubernetes readiness probes.

```zig
server.use(httpx.middleware.readinessProbe(.{
    .path = "/ready",
    .body = "{\"ready\":true}",
    .status = 200,
}));
```

`ReadinessConfig` fields:

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"/ready"` | Path to intercept |
| `body` | `"{\"ready\":true}"` | Response body |
| `status` | `200` | HTTP status code |

### `reverseProxy`

Comptime reverse proxy that forwards all incoming requests to a fixed backend URL.

```zig
server.use(httpx.middleware.reverseProxy("http://backend.internal:8080"));
```

### `reverseProxyRuntime`

Runtime-URL reverse proxy for cases where the target URL is not known at compile time.

```zig
const target = getTargetUrl(); // runtime value
server.use(httpx.middleware.reverseProxyRuntime(target));
```

## Creating Custom Middleware

A middleware is a struct with a `handler` function:

```zig
pub fn timingMiddleware() httpx.Middleware {
    return .{
        .name = "timing",
        .handler = struct {
            fn handler(ctx: *httpx.Context, next: httpx.NextFn) anyerror!httpx.Response {
                const t0 = std.time.nanoTimestamp();
                const resp = try next(ctx);
                const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - t0, 1_000_000);
                std.debug.print("{s} {s} — {d}ms\n", .{
                    @tagName(ctx.request.method),
                    ctx.request.uri.path,
                    elapsed_ms,
                });
                return resp;
            }
        }.handler,
    };
}
```
