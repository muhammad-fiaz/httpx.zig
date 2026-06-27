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
- **RateLimit**: Simple in-memory rate limiting.
- **BasicAuth**: RFC 7617 Basic Authentication.
- **Helmet**: Security headers.
- **Compression**: Helper for content encoding.
- **RequestId**: Injects `X-Request-ID`.

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
