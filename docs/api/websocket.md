# API: WebSocket

The `httpx.websocket` module provides WebSocket client and server primitives according to RFC 6455, including framing, masking, Sec-WebSocket-Key acceptance, ping/pong heartbeats, and UTF-8 validation.

## Overview

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Client connection
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Server-side upgrade handler
    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    server.ws("/chat", struct {
        pub fn onConnect(conn: *httpx.ws.Connection) void {
            conn.sendText("Welcome to chat!") catch {};
        }
        pub fn onMessage(conn: *httpx.ws.Connection, msg: httpx.ws.Message) void {
            conn.sendText(msg.text) catch {};
        }
        pub fn onClose(conn: *httpx.ws.Connection) void {
            _ = conn;
        }
    });

    try server.run();
}
```

## Opcodes & Frame Types

```zig
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};
```

## Functions

### `httpx.ws.computeAccept(key: []const u8, out_buf: *[28]u8) []const u8`
Computes the RFC 6455 `Sec-WebSocket-Accept` value from a client `Sec-WebSocket-Key` by appending the GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`, computing SHA-1, and Base64-encoding.

### `httpx.ws.buildUpgradeRequest(allocator, host, path) ![]u8`
Builds an HTTP/1.1 WebSocket upgrade handshake request with valid `Sec-WebSocket-Key` and `Upgrade: websocket`.

## Related

* [Guide: WebSockets](/guide/websockets)
* [Example: WebSocket Server](/examples/websocket-server)
