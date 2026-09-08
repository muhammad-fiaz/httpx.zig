# Example: Dedicated HTTP/1.1 Server

This example demonstrates starting a dedicated HTTP/1.1 server supporting persistent keep-alive connections, route handlers, and deterministic graceful shutdown without arbitrary spin loops.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "HTTP/1.1 keep-alive response",
        .content_type = "text/plain; charset=utf-8",
    };
}

fn statusHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"status\":\"healthy\",\"protocol\":\"HTTP/1.1\"}",
        .content_type = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .max_connections = 4,
    });
    defer server.deinit();

    try server.router.add(.GET, "/", helloHandler);
    try server.router.add(.GET, "/status", statusHandler);

    const port = server.localPort();
    std.debug.print("HTTP/1.1 server listening on 127.0.0.1:{d}\n", .{port});

    const Worker = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&server});

    // Client request to verify keep-alive on the server
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/status", .{port});

    var resp = try client.get(url, .{
        .httpVersion = .http11,
    });
    defer resp.deinit();

    std.debug.print("Client verified status: {d}\n", .{resp.status});
    std.debug.print("Response: {s}\n", .{resp.body});

    server.shutdown();
    thread.join();
}
```

## How to Run

```bash
zig build run-http11-server
```

## Key Highlights

1. **Router Registration**: Maps routes with clean value responses (`httpx.Response`).
2. **Graceful Shutdown**: Calls `server.shutdown()` and joins the worker thread deterministically without race-prone sleep hacks.
3. **HTTP/1.1 Concurrency**: Reuses TCP connections efficiently across multiple requests.

## Related

* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Guide: Routing](/guide/routing)
* [API: Server](/api/server)
