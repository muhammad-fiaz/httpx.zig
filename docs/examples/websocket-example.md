# WebSocket Example

Demonstrates how to use the built-in WebSocket support (`RFC 6455`) in `httpx.zig` using a clean, straightforward API surface.

## Features Covered

- **Upgrade Request Detection**: Checking incoming HTTP requests for `Upgrade: websocket` headers.
- **Handshake Key Calculations**: Computing `Sec-WebSocket-Accept` from `Sec-WebSocket-Key` using standard SHA-1 and Base64 algorithms.
- **Opcode Primitives**: Handling text, binary, ping, pong, and close frames.
- **Payload Framing**: Handling 1-byte, 2-byte, and 8-byte frame length encodings.
- **Masking Support**: Applying and decoding masking keys on client-sent payloads.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compute WebSocket Handshake Accept Key
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try httpx.wsAcceptKey(client_key, allocator);
    defer allocator.free(accept);
    std.debug.print("Accept key: {s}\n", .{accept});

    // Detect Upgrade Request
    var req = try httpx.Request.init(allocator, .GET, "ws://localhost:8080/chat");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try req.headers.set("Sec-WebSocket-Key", client_key);

    std.debug.print("Is upgrade: {}\n", .{httpx.isWebSocketUpgrade(&req)});

    // Encode and Decode a Text Frame
    const frame_bytes = try httpx.wsTextFrame(allocator, "Hello, WebSocket!");
    defer allocator.free(frame_bytes);

    var decoded = try httpx.wsDecodeFrame(allocator, frame_bytes);
    defer decoded.frame.deinit();
    std.debug.print("Opcode: {s}, Payload: {s}\n", .{ @tagName(decoded.frame.opcode), decoded.frame.payload });
}
```

## Running the Example

Run the pre-configured WebSocket example:

```bash
zig build run-all-websocket_example
```
