# HTTP/2 Server Runtime Example

Run a full local end-to-end HTTP/2 server route with the high-level server runtime (`http2_enabled = true`).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .http2_enabled = true,
    });
    defer server.deinit();

    try server.get("/h2", struct {
        fn handler(ctx: *httpx.Context) !httpx.Response {
            return ctx.text("hello from http2 server runtime");
        }
    }.handler);

    try server.listen();
}
```

## Run

```bash
zig build run-all-http2_server_runtime
```

## What to Verify

- The response version prints `HTTP/2`.
- The server accepts an HTTP/2 preface and request HEADERS/DATA flow.
- The route response is emitted through HTTP/2 HEADERS/DATA frames.
