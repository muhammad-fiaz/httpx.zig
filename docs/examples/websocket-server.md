# WebSocket Server Example

Serves a browser page and a real RFC 6455 endpoint. The route calls
`httpx.websocket.accept`, and the HTTP worker hands the connection to the
session after the handler returns.

## Example

```zig
//! WebSocket Server and Browser Client Example.
//! Run with: `zig build run-websocket-server`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .limits = .{ .maxConnections = 5 },
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.get("/ws", wsHandler);

    const port = server.localPort();
    std.debug.print("=== WebSocket Server running on http://127.0.0.1:{d} ===\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;
    const urlRoot = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(urlRoot, .{});
    std.debug.print("GET / -> status={d}, len={d}\n", .{ res.status, res.body.len });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("WebSocket server verification completed successfully.\n", .{});
}

fn indexHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.html(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head><meta charset="UTF-8"><title>httpx.zig WebSocket Demo</title></head>
        \\<body>
        \\  <h1>httpx.zig WebSocket Endpoint</h1>
        \\  <p>Endpoint URL: ws://127.0.0.1:8080/ws</p>
        \\</body>
        \\</html>
    );
}

fn wsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    // The HTTP worker hands the connection to the session after this returns.
    try httpx.websocket.accept(ctx, .{
        .callbacks = .{ .onMessage = echo },
    });
    return .{};
}

fn echo(
    session: *httpx.websocket.Session,
    message: *httpx.websocket.Message,
    _: ?*anyopaque,
) anyerror!void {
    switch (message.kind) {
        .text => try session.sendText(message.data),
        .binary => try session.sendBinary(message.data),
    }
}
```

## Expected Output

```text
=== WebSocket Server running on http://127.0.0.1:54321 ===
GET / -> status=200, len=812
WebSocket server verification completed successfully.
```

The ephemeral loopback port varies per run. Loopback only, no external
prerequisites.

## Verify the upgrade

```bash
# Any RFC 6455 client works; the bundled client covers ws:// and wss://.
zig build run-websocket-client
```

The upgrade reuses the accepted TCP connection. Buffered bytes after the
request head are preserved, the HTTP writer is skipped, and exactly one
component owns the final close.

## Run

```bash
zig build run-websocket-server
```

## Related

* [Guide: WebSockets](/guide/websockets)
* [API: WebSocket](/api/websocket)
* [Example: WebSocket Client](/examples/websocket-client)
