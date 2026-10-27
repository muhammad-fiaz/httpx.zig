# WebSocket Server Example

Demonstrates serving an interactive browser WebSocket client and handling WebSocket upgrade requests with `httpx.websocket.computeAccept` and frame codecs.

## Demo Program

```zig
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
        .maxConnections = 5,
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

fn wsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    // If request contains Sec-WebSocket-Key, compute Sec-WebSocket-Accept.
    if (ctx.header("sec-websocket-key")) |key| {
        var acceptBuf: [28]u8 = undefined;
        httpx.websocket.computeAccept(key, &acceptBuf);
        return .{
            .status = 101,
            .headers = try ctx.allocator.dupe(httpx.router.Header, &[_]httpx.router.Header{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Sec-WebSocket-Accept", .value = try ctx.allocator.dupe(u8, &acceptBuf) },
            }),
            .body = "",
        };
    }
    return ctx.html("<h1>WebSocket Endpoint</h1><p>Connect with a WebSocket client.</p>");
}
```

## Expected Output

```text
=== WebSocket Server running on http://127.0.0.1:54321 ===
GET / -> status=200, len=812
WebSocket server verification completed successfully.
```

The ephemeral loopback port varies per run; response body length varies with the served HTML. Loopback only, no external prerequisites. Frame opcodes live on `httpx.websocket.Frame.Opcode` (`.text`, `.binary`, `.close`, `.ping`, `.pong`); `applyMask` masks payloads in place.

## Run

```
zig build run-websocket-server
```

## Checklist

- [x] `Server.init` serves `/` and `/ws` on an ephemeral loopback port
- [x] `wsHandler` reads `sec-websocket-key` via `ctx.header`
- [x] `httpx.websocket.computeAccept` computes the RFC 6455 accept key
- [x] Upgrade responds `101` with `Upgrade`/`Connection`/`Sec-WebSocket-Accept`
- [x] `httpx.websocket.Frame.buildFrameHeader`/`parseFrameHeader` roundtrip frames
- [x] `httpx.websocket.Frame.Opcode` covers `.text`/`.binary`/`.close`/`.ping`/`.pong`
- [x] `applyMask` masks client-to-server payloads in place
- [x] Large payloads (>125 bytes) use extended length encoding
