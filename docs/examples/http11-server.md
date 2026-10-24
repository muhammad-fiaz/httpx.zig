# Example: Dedicated HTTP/1.1 Server

This example demonstrates starting a dedicated HTTP/1.1 server supporting persistent keep-alive connections, route handlers, and deterministic graceful shutdown without arbitrary spin loops.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "HTTP/1.1 keep-alive response",
        .contentType = "text/plain; charset=utf-8",
    };
}

fn statusHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "{\"status\":\"healthy\",\"protocol\":\"HTTP/1.1\"}",
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    });
    defer server.deinit();

    try server.router.add(.GET, "/", helloHandler, .{});
    try server.router.add(.GET, "/status", statusHandler, .{});

    const port = server.localPort();
    std.debug.print("HTTP/1.1 server listening on 127.0.0.1:{d}\n", .{port});

    const thread = try server.start();

    // Client request to verify keep-alive on the server
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/status", .{port});

    var resp = try client.get(url, .{
        .httpVersion = .http11,
    });
    defer resp.deinit();

    std.debug.print("Client verified status: {d}\n", .{resp.status});
    std.debug.print("Response: {s}\n", .{resp.body});

    thread.join();
}
```

## Expected Output

```text
HTTP/1.1 server listening on 127.0.0.1:54321
Client verified status: 200
Response: {"status":"healthy","protocol":"HTTP/1.1"}
```

Port varies per run (ephemeral port); status is 200 on success with the JSON body shown.

## How to Run

```bash
zig build run-http11-server
```

## Key Highlights

1. **Router Registration**: Maps routes with clean value responses (`httpx.web.router.Response`).
2. **Graceful Shutdown**: Calls `server.start()` and joins the worker thread deterministically without race-prone sleep hacks.
3. **HTTP/1.1 Concurrency**: Reuses TCP connections efficiently across multiple requests.

## Related

* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Guide: Routing](/guide/routing)
* [API: Server](/api/server)
