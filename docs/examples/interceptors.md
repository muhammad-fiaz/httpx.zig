# Interceptors

Apply request/response interceptors to inject shared behavior.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn onRequest(req: *httpx.Request, _: ?*anyopaque) !void {
    try req.setHeader("X-Intercepted", "true");
}

fn onResponse(res: *httpx.Response, _: ?*anyopaque) !void {
    std.debug.print("intercepted status={d}\n", .{res.status.code});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    try client.addInterceptor(.{
        .request_fn = onRequest,
        .response_fn = onResponse,
    });

    var res = try client.get("https://httpbin.org/get", .{});
    defer res.deinit();
}
```

## Run

```bash
zig build run-interceptors
```

## What to Verify

- Request interceptor injects the custom header.
- Response interceptor executes for successful responses.
