# Interceptors

Interceptors are powerful hooks that allow you to safeguard or modify requests and responses globally.

Common use cases include:
- Adding authentication tokens to every request.
- Logging request/response details.
- Automating error handling or retry logic beyond the built-in policy.
- Transforming response data.

## Setup

Interceptors are defined using the `Interceptor` struct and added to the client.

```zig
pub const Interceptor = struct {
    request_fn: ?RequestInterceptor = null,
    response_fn: ?ResponseInterceptor = null,
    context: ?*anyopaque = null,
};
```

## Example: Auth Token Injector

This interceptor adds a Bearer token to every outgoing request.

```zig
fn addAuthToken(req: *httpx.Request, ctx: ?*anyopaque) !void {
    // In a real app, you might cast ctx to a Config struct
    try req.headers.set("Authorization", "Bearer my-secret-token");
}

// Usage
var client = httpx.Client.init(allocator);
try client.addInterceptor(.{
    .request_fn = addAuthToken,
    // response_fn can be null
});
```

## Example: Response Logger

```zig
fn logResponse(res: *httpx.Response, ctx: ?*anyopaque) !void {
    std.debug.print("Status: {d}\n", .{res.status.code});
}

try client.addInterceptor(.{
    .response_fn = logResponse,
});
```

You can chain multiple interceptors. They will be executed in the order they were added.
