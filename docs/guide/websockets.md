# WebSockets Guide

`httpx.zig` provides RFC 6455 WebSocket primitives: upgrade handshake helpers
and binary framing. Everything lives under `httpx.websocket`.

## What WebSocket Is

WebSocket (RFC 6455) provides full-duplex communication over a single TCP connection. The protocol starts with an HTTP/1.1 upgrade handshake, then switches to a binary framing protocol for bidirectional messaging between client and server.

The upgrade sequence:

1. Client sends a GET request with `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key: <base64-nonce>`, and `Sec-WebSocket-Version: 13`.
2. Server validates the request, computes the accept key, and responds with `101 Switching Protocols` and `Sec-WebSocket-Accept: <computed-key>`.
3. Both sides communicate using binary frames from that point on.

## Computing the Accept Key

`Handshake.computeAccept` concatenates the client key with the RFC 6455 magic
GUID, SHA-1 hashes the result, and base64-encodes it:

```zig
var accept: [28]u8 = undefined;
httpx.websocket.computeAccept(clientKey, &accept);
// Set as Sec-WebSocket-Accept header value in your 101 response
```

## Upgrade Requests

```zig
const req = try httpx.websocket.Handshake.buildUpgradeRequest(
    allocator, host, path, key, &.{},
);
defer allocator.free(req);
```

Validate a `101` response with
`Handshake.validateUpgradeResponse(head, &expectedAccept)`.

## Encoding Frames

```zig
var hdr: [10]u8 = undefined;
const n = httpx.websocket.Frame.buildFrameHeader(&hdr, true, .text, payload.len, null);
// server-to-client frames are unmasked (maskKey = null)
```

Client-to-server frames must be masked (pass a `[4]u8` key) per RFC 6455;
`Frame.applyMask(data, key)` masks payloads in place. Ping/pong/close use
`Opcode.ping`, `Opcode.pong`, `Opcode.close` with `Opcode.isControl()`.

## Decoding Frames

`Frame.parseFrameHeader(buf)` parses one header and returns the header plus
the number of bytes consumed:

```zig
const parsed = try httpx.websocket.Frame.parseFrameHeader(raw_bytes);
const hdr = parsed.hdr; // fin, opcode, masked, payloadLen, maskKey
// payload follows at raw_bytes[parsed.consumed..]
```

## Full Example

See `examples/websocketServer.zig`, which computes the accept key and returns
a `101 Switching Protocols` response from a route:

```zig
fn wsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const key = ctx.header("sec-websocket-key") orelse
        return ctx.text("WebSocket upgrade required");
    var accept: [28]u8 = undefined;
    httpx.websocket.computeAccept(key, &accept);
    return .{
        .status = 101,
        .headers = &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Sec-WebSocket-Accept", .value = try ctx.allocator.dupe(u8, &accept) },
        },
    };
}
```

The high-level server has no post-upgrade frame loop: after the `101` it does
not take over the socket for WebSocket messages. Use the framing primitives
with a raw TCP transport for a complete WebSocket session.

## Types

| Type | Description |
|------|-------------|
| `Frame.Opcode` | Frame opcode: `continuation`, `text`, `binary`, `close`, `ping`, `pong` |
| `Frame.FrameHeader` | Decoded header: `fin`, `opcode`, `masked`, `payloadLen`, `maskKey` |
