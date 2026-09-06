# HTTP/3 Server Runtime Example

Run a full local end-to-end HTTP/3 server route over UDP with the high-level server runtime (`http3_enabled = true`).

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
        .http3_enabled = true,
        .http2_enabled = false,
    });
    defer server.deinit();

    try server.get("/h3", struct {
        fn handler(ctx: *httpx.Context) !httpx.Response {
            return ctx.text("hello from http3 server runtime");
        }
    }.handler);

    try server.listen();
}
```

## Run

```bash
zig build run-all-http3_server_runtime
```

## What to Verify

- The response version prints `HTTP/3`.
- The server receives UDP datagrams carrying QUIC STREAM and HTTP/3 frames.
- The route response is emitted through HTTP/3 HEADERS/DATA frames.
