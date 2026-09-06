# Utilities API

Centralized API documentation for all utility modules.

## Module Index

| Module | Location | Description |
|--------|----------|-------------|
| [IO](/api/io) | `src/io/` | AnyIO, Buffer, FixedBuffer, BufferPool, encoding helpers |
| [Compression](/api/compression) | `src/compress/` | gzip/deflate/brotli/zstd compress/decompress, streaming |
| [Cache](/api/cache) | `src/cache/` | HttpCache (LRU + TTL), ConditionalGet (ETag) |
| [Data](/api/data) | `src/data/` | MIME types, multipart, JSON builder, shared helpers |
| [Metrics](/api/metrics) | `src/metrics/` | Thread-safe request/response metrics |
| [Session](/api/session) | `src/session/` | TTL-based in-memory session store |
| [SSE](/api/sse) | `src/protocol/sse.zig` | Server-Sent Events parsing and streaming |

## Quick Reference

### Encoding

- `httpx.encodeVarInt(...)` / `httpx.decodeVarInt(...)` — QUIC variable-length integer encoding

### WebSocket

See [Protocol API](/api/protocol) for the full WebSocket section. Root-level aliases:

- `httpx.isWebSocketUpgrade(req)` — checks upgrade headers
- `httpx.wsExtractKey(req)` — returns `Sec-WebSocket-Key` value
- `httpx.wsAcceptKey(key, allocator)` — computes `Sec-WebSocket-Accept`
- `httpx.wsEncodeFrame(allocator, opcode, payload, fin, masked, mask_key)` — low-level frame encoder
- `httpx.wsDecodeFrame(allocator, data)` — decode one frame, returns `WsDecodeResult`
- `httpx.wsTextFrame(allocator, text)` — encode server text frame
- `httpx.wsBinaryFrame(allocator, data)` — encode server binary frame
- `httpx.wsPingFrame(allocator, data)` — encode ping frame
- `httpx.wsPongFrame(allocator, data)` — encode pong frame
- `httpx.wsCloseFrame(allocator, code, reason)` — encode close frame
- `httpx.WsOpcode` — frame opcode enum
- `httpx.WsFrame` — decoded frame struct
- `httpx.WsCloseCode` — close status codes
- `httpx.WsDecodeResult` — `{ frame, consumed }`
- `httpx.WS_GUID` — RFC 6455 magic GUID
