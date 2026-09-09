# WebSocket Example

WebSocket handshake and framing primitives (`httpx.websocket`, RFC 6455).
See `examples/websocket_server.zig`.

```zig
// Compute Sec-WebSocket-Accept for an upgrade response.
var accept: [28]u8 = undefined;
httpx.websocket.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);

// Encode a server-to-client text frame header.
var hdr: [10]u8 = undefined;
const n = httpx.websocket.Frame.buildFrameHeader(&hdr, true, .text, 5, null);
_ = n;

// Decode a frame header.
const parsed = try httpx.websocket.Frame.parseFrameHeader(raw);
const frameHdr = parsed.hdr; // fin, opcode, masked, payloadLen, maskKey
```

Opcodes live on `httpx.websocket.Frame.Opcode` (`.text`, `.binary`,
`.close`, `.ping`, `.pong`); `applyMask` masks payloads in place.

## Run

```bash
zig build run-websocket-server
```

## What to Verify

- The browser client page returns 200.
- Handshake accept keys match the RFC 6455 test vector.
