# Authentication Guide

HTTPX provides native, unified authentication primitives for both HTTP client requests and HTTP server middleware, supporting HTTP Basic Auth (RFC 7617), Bearer Tokens (RFC 6750), API keys, and custom authentication schemes.

## Client-Side Authentication

Authentication credentials can be configured per request using the unified request options structure:

### Basic Authentication
```zig
const response = try client.get("https://api.example.com/protected", .{
    .basic_auth = .{
        .username = "admin",
        .password = "secret123",
    },
});
defer response.deinit();
```
Under the hood, HTTPX automatically base64-encodes the credentials and injects the `Authorization: Basic <base64>` header.

### Bearer Token Authentication
```zig
const response = try client.post("https://api.example.com/v1/orders", .{
    .bearer_auth = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
    .json = .{ .item_id = 901, .quantity = 2 },
});
defer response.deinit();
```
This adds `Authorization: Bearer <token>` to the outgoing request.

### API Key Authentication
API keys can be supplied either via custom headers or query parameters:
```zig
const response = try client.get("https://api.example.com/data", .{
    .headers = &.{
        .{ .name = "X-API-Key", .value = "my-secret-key-xyz" },
    },
});
defer response.deinit();
```

---

## Server-Side Authentication

On the server, HTTPX provides standard authentication middleware and extractor utilities.

```zig
const std = @import("std");
const httpx = @import("httpx");

fn requireApiKey(ctx: *httpx.Context) !bool {
    const key = ctx.header("X-API-Key") orelse {
        ctx.status(401);
        try ctx.json(.{ .error = "Missing X-API-Key header" });
        return false;
    };

    if (!std.mem.eql(u8, key, "expected-secret-key")) {
        ctx.status(403);
        try ctx.json(.{ .error = "Invalid API Key" });
        return false;
    }
    return true;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // Secure endpoint using middleware check
    server.get("/secure/data", struct {
        fn handle(ctx: *httpx.Context) !void {
            if (!try requireApiKey(ctx)) return;
            try ctx.json(.{ .status = "access granted", .data = 42 });
        }
    }.handle);

    try server.run();
}
```

## Security Best Practices

1. **Always Use HTTPS**: Never transmit Basic auth credentials or Bearer tokens over cleartext HTTP.
2. **Prevent Token Leakage**: HTTPX strips Authorization headers when following 3xx redirects to a different host/origin.
3. **Constant-Time Comparison**: When validating passwords or API tokens, use constant-time equality checks (`std.crypto.utils.timingSafeEql`) to prevent timing attacks.

## Related

* [API: Request](/api/request)
* [Security: Overview](/security/overview)
* [Example: Auth Helpers](/examples/http-auth-helpers)
