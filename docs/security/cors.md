# CORS (Cross-Origin Resource Sharing)

Cross-Origin Resource Sharing (CORS) is a W3C mechanism allowing web applications loaded in one origin to access resources located on a different domain.

## HTTPX CORS Middleware

HTTPX provides standard CORS handling:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // CORS pre-flight & headers handler
    server.use(struct {
        fn cors(ctx: *httpx.Context) !void {
            ctx.header("Access-Control-Allow-Origin", "https://app.example.com");
            ctx.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
            ctx.header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key");
            ctx.header("Access-Control-Max-Age", "86400");

            if (ctx.request.method == .OPTIONS) {
                ctx.status(204);
                return;
            }
            try ctx.next();
        }
    }.cors);

    server.get("/api/user", struct {
        fn handle(ctx: *httpx.Context) !void {
            try ctx.json(.{ .user = "Alice" });
        }
    }.handle);

    try server.run();
}
```

## Security Recommendations

1. **Avoid `*` with Credentials**: Never pair `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true`.
2. **Whitelist Exact Origins**: Validate the incoming `Origin` header against an explicit allowed set rather than echoing arbitrary origins.

## Related

* [Security: Headers](/security/headers)
* [Example: CORS Server](/examples/cors-server)
