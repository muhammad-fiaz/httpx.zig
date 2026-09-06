# WebSockets Guide

`httpx.zig` supports RFC 6455 WebSockets with a flat API for upgrade detection, handshake key computation, and binary framing. No wrapper namespaces — everything is accessible directly from `httpx`.

## What WebSocket Is

WebSocket (RFC 6455) provides full-duplex communication over a single TCP connection. The protocol starts with an HTTP/1.1 upgrade handshake, then switches to a binary framing protocol for bidirectional messaging between client and server.

The upgrade sequence:

1. Client sends a GET request with `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key: <base64-nonce>`, and `Sec-WebSocket-Version: 13`.
2. Server validates the request, computes the accept key, and responds with `101 Switching Protocols` and `Sec-WebSocket-Accept: <computed-key>`.
3. Both sides communicate using binary frames from that point on.

## Server Upgrade Detection

Use `isWebSocketUpgrade` to check whether an incoming request is a WebSocket upgrade:

```zig
const httpx = @import("httpx");

fn wsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (!httpx.isWebSocketUpgrade(&ctx.request)) {
        return ctx.status(400).text("Not a WebSocket upgrade");
    }

    const client_key = httpx.wsExtractKey(&ctx.request).?;
    const accept = try httpx.wsAcceptKey(client_key, ctx.allocator);
    defer ctx.allocator.free(accept);

    _ = try ctx.response.header("Upgrade", "websocket");
    _ = try ctx.response.header("Connection", "Upgrade");
    _ = try ctx.response.header("Sec-WebSocket-Accept", accept);
    return ctx.status(101).build();
}
```

`isWebSocketUpgrade` checks for all three required headers: `Upgrade: websocket`, `Connection: Upgrade`, and a non-empty `Sec-WebSocket-Key`.

## Computing the Accept Key

`wsAcceptKey` concatenates the client key with the RFC 6455 magic GUID, SHA-1 hashes the result, and base64-encodes it:

```zig
const accept = try httpx.wsAcceptKey(client_key, allocator);
defer allocator.free(accept);
// Set as Sec-WebSocket-Accept header value in your 101 response
```

The `WS_GUID` constant (`"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`) is also exported if you need it directly.

## Encoding Frames

### Text and binary frames

```zig
// Server-to-client text frame (unmasked, fin=true)
const frame = try httpx.wsTextFrame(allocator, "Hello, client!");
defer allocator.free(frame);
try conn.writeAll(frame);

// Binary frame
const bin = try httpx.wsBinaryFrame(allocator, &[_]u8{ 0x01, 0x02, 0x03 });
defer allocator.free(bin);
```

### Ping and pong frames

```zig
const ping = try httpx.wsPingFrame(allocator, "");
defer allocator.free(ping);

const pong = try httpx.wsPongFrame(allocator, "");
defer allocator.free(pong);
```

### Close frame

```zig
const close = try httpx.wsCloseFrame(allocator, .normal, "goodbye");
defer allocator.free(close);
```

`WsCloseCode` values: `normal` (1000), `going_away` (1001), `protocol_error` (1002), `unsupported_data` (1003), `invalid_payload` (1007), `policy_violation` (1008), `message_too_big` (1009), `internal_error` (1011).

### Low-level frame encoding

`wsEncodeFrame` gives full control:

```zig
const frame = try httpx.wsEncodeFrame(
    allocator,
    .text,        // WsOpcode
    "hello",      // payload
    true,         // fin
    false,        // masked (false for server-to-client)
    .{ 0, 0, 0, 0 }, // mask key (ignored when masked=false)
);
defer allocator.free(frame);
```

Client-to-server frames must be masked (`masked = true`) per RFC 6455.

## Decoding Frames

`wsDecodeFrame` parses one frame from a byte slice and returns the frame plus the number of bytes consumed:

```zig
const result = try httpx.wsDecodeFrame(allocator, raw_bytes);
var frame = result.frame;
defer frame.deinit();

switch (frame.opcode) {
    .text => std.debug.print("text: {s}\n", .{frame.payload}),
    .binary => std.debug.print("binary: {d} bytes\n", .{frame.payload.len}),
    .ping => {
        // send pong with same payload
        const pong = try httpx.wsPongFrame(allocator, frame.payload);
        defer allocator.free(pong);
        try conn.writeAll(pong);
    },
    .close => std.debug.print("close received\n", .{}),
    else => {},
}

// result.consumed tells you how many bytes were used
```

Returns `error.NeedMoreData` if the buffer contains an incomplete frame.

## Full Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/ws", struct {
        fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
            if (!httpx.isWebSocketUpgrade(&ctx.request)) {
                return ctx.status(400).text("WebSocket upgrade required");
            }

            const key = httpx.wsExtractKey(&ctx.request) orelse
                return ctx.status(400).text("Missing Sec-WebSocket-Key");

            const accept = try httpx.wsAcceptKey(key, ctx.allocator);
            defer ctx.allocator.free(accept);

            _ = try ctx.response.header("Upgrade", "websocket");
            _ = try ctx.response.header("Connection", "Upgrade");
            _ = try ctx.response.header("Sec-WebSocket-Accept", accept);
            return ctx.status(101).build();
        }
    }.handler);

    try server.listen();
}
```

## Types

| Type | Description |
|------|-------------|
| `WsOpcode` | Frame opcode: `continuation`, `text`, `binary`, `close`, `ping`, `pong` |
| `WsFrame` | Decoded frame: `fin`, `opcode`, `masked`, `payload`. Call `deinit()` to free. |
| `WsCloseCode` | Close status codes per RFC 6455 §7.4 |
| `WsDecodeResult` | `{ frame: WsFrame, consumed: usize }` |
| `WS_GUID` | RFC 6455 magic GUID string |
