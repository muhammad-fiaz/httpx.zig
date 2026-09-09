# API: WebSocket

The `httpx.websocket` module provides WebSocket primitives according to
RFC 6455: handshake helpers and frame encoding/decoding.

## Overview

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compute Sec-WebSocket-Accept for an upgrade response.
    var accept: [28]u8 = undefined;
    httpx.websocket.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);

    // Encode a text frame header.
    var hdr: [10]u8 = undefined;
    const n = httpx.websocket.Frame.buildFrameHeader(&hdr, true, .text, 5, null);
    _ = n;
    _ = allocator;
}
```

## Opcodes & Frame Types

`httpx.websocket.Frame.Opcode` (`.continuation`, `.text`, `.binary`,
`.close`, `.ping`, `.pong`) with `isControl()`, plus `FrameHeader`
(`fin`, `opcode`, `masked`, `payloadLen`, `maskKey`).

## Functions

### `httpx.websocket.computeAccept(key, out)`

Computes the RFC 6455 `Sec-WebSocket-Accept` value from a client
`Sec-WebSocket-Key` (SHA-1 over key + GUID, Base64-encoded).

### `httpx.websocket.Handshake.buildUpgradeRequest(allocator, host, path, key, headers)`

Builds an HTTP/1.1 WebSocket upgrade handshake request with a valid
`Sec-WebSocket-Key` and `Upgrade: websocket`.

### `httpx.websocket.Handshake.validateUpgradeResponse(head, accept)`

Validates a `101` response against the expected accept key.

### `httpx.websocket.Frame.parseFrameHeader(buf)` / `buildFrameHeader(...)`

Decode/encode frame headers; `applyMask(data, key)` masks payloads in place.

## Related

* [Guide: WebSockets](/guide/websockets)
* [Example: WebSocket Server](/examples/websocket-server)
