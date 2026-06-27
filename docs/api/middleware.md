# Middleware API

Middleware functions sit between the incoming request and your route handlers. They are useful for logging, authentication, CORS, compression, and more.

## Usage

Global middleware is added using `server.use()`.

```zig
// Add logging middleware
try server.use(httpx.middleware.logger());

// Add CORS middleware
try server.use(httpx.middleware.cors(.{}));
```

## Built-in Middleware

`httpx.zig` comes with several built-in middlewares in `httpx.middleware`.

### `logger`

Logs request method, path, and detailed timing information to `std.debug` by default.

```zig
server.use(httpx.middleware.logger());
```

To route logs into your own sink, use `loggerWithConfig`:

```zig
const httpx = @import("httpx");
const std = @import("std");
const allocator = std.heap.page_allocator;

var server = httpx.Server.init(allocator);
const CustomLogger = struct {
    fn log(level: httpx.LogLevel, message: []const u8) void {
        _ = level;
        std.debug.print("{s}", .{message});
    }
};

server.use(httpx.middleware.loggerWithConfig(.{ .log_fn = CustomLogger.log }));
```

To disable request logging, simply do not install the logger middleware.

### `cors`

Handles Cross-Origin Resource Sharing (CORS) headers.

```zig
const corsConfig = httpx.middleware.CorsConfig{
    .allowed_origins = &[_][]const u8{"https://example.com"},
    .allowed_methods = &[_]Method{.GET, .POST},
    .allowed_headers = &[_][]const u8{"Content-Type", "Authorization"},
    .exposed_headers = &[_][]const u8{"X-Request-ID"},
    .allow_credentials = true,
    .max_age = 86400,
};
server.use(httpx.middleware.cors(corsConfig));
```

The middleware automatically:

- Applies `Access-Control-Allow-Origin` with origin-aware matching.
- Sets `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers` from config.
- Sets `Access-Control-Expose-Headers` when configured.
- Sets `Access-Control-Allow-Credentials: true` when enabled.
- Handles preflight `OPTIONS` requests with `204 No Content`.

### `rateLimit`

Basic in-memory rate limiting.

```zig
const config = httpx.middleware.RateLimitConfig{
    .max_requests = 100, // requests per window
    .window_ms = 60_000, // 1 minute
};
server.use(httpx.middleware.rateLimit(config));
```

### `basicAuth`

Implements HTTP Basic Authentication.

```zig
fn validateUser(user: []const u8, pass: []const u8) bool {
    // Check credentials...
    return true;
}

server.use(httpx.middleware.basicAuth("My Realm", validateUser));
```

### `compression`

Handles `Accept-Encoding` negotiation (implementation internal).

```zig
server.use(httpx.middleware.compression());
```

### `helmet`

Adds various security headers (like HSTS, X-Frame-Options, etc.).

```zig
server.use(httpx.middleware.helmet());
```

### `requestId`

Generates and attaches a unique `X-Request-ID` to every request.

```zig
server.use(httpx.middleware.requestId());
```

## Creating Custom Middleware

A middleware is a struct with a `handler` function.

```zig
const httpx = @import("httpx");

pub fn myMiddleware() httpx.Middleware {
    return .{
        .name = "my_middleware",
        .handler = struct {
            fn handler(ctx: *httpx.Context, next: httpx.server.middleware.Next) anyerror!httpx.Response {
                // Pre-processing
                std.debug.print("Before request\n", .{});

                // Call next middleware
                const response = try next(ctx);

                // Post-processing
                std.debug.print("After request\n", .{});

                return response;
            }
        }.handler,
    };
}
```
