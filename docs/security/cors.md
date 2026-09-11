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

    // Built-in CORS middleware (handles pre-flight + headers)
    try server.use(httpx.middleware.cors);

    try server.get("/api/user", userHandler);
    try server.run();
}

fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx;
    return .{ .status = 200, .body = "{\"user\":\"Alice\"}", .contentType = "application/json" };
}
```

## Security Recommendations

1. **Avoid `*` with Credentials**: Never pair `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true`.
2. **Whitelist Exact Origins**: Validate the incoming `Origin` header against an explicit allowed set rather than echoing arbitrary origins.

## Related

* [Security: Headers](/security/headers)
* [Example: CORS Server](/examples/cors-server)
