# WebSocket Example

Low-level RFC 6455 handshake and frame primitives from
`httpx.websocket.protocol`. Most applications should use the high-level
[server](/examples/websocket-server) and [client](/examples/websocket-client)
instead.

```zig
// Compute Sec-WebSocket-Accept for an upgrade response.
var accept: [28]u8 = undefined;
httpx.websocket.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);

// Encode a server-to-client text frame header.
var hdr: [10]u8 = undefined;
const n = httpx.websocket.protocol.Frame.buildFrameHeader(&hdr, true, .text, 5, null);
_ = n;

// Decode a frame header.
const parsed = try httpx.websocket.protocol.Frame.parseFrameHeader(raw);
const frameHdr = parsed.hdr; // fin, opcode, masked, payloadLen, maskKey
```

Opcodes live on `httpx.websocket.Opcode` (`.text`, `.binary`, `.close`,
`.ping`, `.pong`); `protocol.Frame.applyMask` masks payloads in place.

## Expected Output

```text
(no output - framing primitives only; RFC 6455 accept for "dGhlIHNhbXBsZSBub25jZQ==" is "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
```

The RFC 6455 test vector above is fixed. For a live echo session, run the
server and client examples.

## Run

```bash
zig build run-websocket-server
zig build run-websocket-client
```

## Related

* [Guide: WebSockets](/guide/websockets)
* [API: WebSocket](/api/websocket)
