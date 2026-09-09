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
httpx.websocket.computeAccept(client_key, &accept);
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
`Handshake.validateUpgradeResponse(head, &expected_accept)`.

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

See `examples/websocket_server.zig`, which serves an interactive browser
WebSocket client and verifies the endpoint:

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 0 });
defer server.deinit();

try server.get("/", htmlHandler); // serves the browser client page

const thread = try server.start();
defer thread.join();
defer server.requestShutdown();
```

## Types

| Type | Description |
|------|-------------|
| `Frame.Opcode` | Frame opcode: `continuation`, `text`, `binary`, `close`, `ping`, `pong` |
| `Frame.FrameHeader` | Decoded header: `fin`, `opcode`, `masked`, `payloadLen`, `maskKey` |
