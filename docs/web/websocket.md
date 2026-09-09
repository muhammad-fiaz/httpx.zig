# WebSocket Server & Client

HTTPX implements RFC 6455 WebSocket primitives: handshake helpers and frame
encoding/decoding. Serve upgrade-capable routes from a normal `Server` (see
`examples/websocket_server.zig`, which serves an interactive browser client
and verifies the endpoint over HTTP).

## Handshake (`httpx.websocket.Handshake`)

| Function | Description |
|----------|-------------|
| `computeAccept(key, out)` | Compute `Sec-WebSocket-Accept` from the client key |
| `buildUpgradeRequest(allocator, host, path, key, headers)` | Build a client upgrade request head |
| `validateUpgradeResponse(head, accept)` | Validate a `101` response against the expected accept key |

## Frames (`httpx.websocket.Frame`)

| Member | Description |
|--------|-------------|
| `Opcode` | Frame opcodes (`.text`, `.binary`, `.close`, ...) |
| `FrameHeader` | Parsed header: `fin`, `opcode`, `masked`, `payloadLen`, `maskKey` |
| `parseFrameHeader(buf)` | Parse a header, returning header + bytes consumed |
| `buildFrameHeader(out, fin, opcode, payloadLen, maskKey)` | Encode a header |
| `applyMask(data, key)` | Apply/unapply the masking key in place |
| `generateKey(random, out)` | Random client masking material |

## Related

* [API: WebSocket](/api/websocket)
* [Guide: WebSockets](/guide/websockets)
* [Example: WebSocket Server](/examples/websocket-server)
