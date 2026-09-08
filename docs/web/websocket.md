# WebSocket Server & Client

HTTPX implements full RFC 6455 WebSockets, enabling bidirectional, full-duplex communication for real-time web applications.

## WebSocket Server

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

    server.ws("/ws/chat", struct {
        pub fn onConnect(conn: *httpx.ws.Connection) void {
            conn.sendText("Connected to chat server") catch {};
        }

        pub fn onMessage(conn: *httpx.ws.Connection, msg: httpx.ws.Message) void {
            // Echo message back to sender
            conn.sendText(msg.text) catch {};
        }

        pub fn onClose(conn: *httpx.ws.Connection) void {
            _ = conn;
        }
    });

    try server.run();
}
```

## Handshake Flow

1. Browser initiates HTTP upgrade:
   ```http
   GET /ws/chat HTTP/1.1
   Host: server.example.com
   Upgrade: websocket
   Connection: Upgrade
   Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
   Sec-WebSocket-Version: 13
   ```
2. HTTPX server validates headers and computes `Sec-WebSocket-Accept`.
3. Server responds with `101 Switching Protocols`.
4. TCP connection switches to framed binary/text WebSocket protocol.

## Related

* [API: WebSocket](/api/websocket)
* [Guide: WebSockets](/guide/websockets)
* [Example: WebSocket Server](/examples/websocket-server)
