# Utilities API

Centralized API documentation for all utility modules.

## Module Index

| Module | Location | Description |
|--------|----------|-------------|
| [IO](/api/io) | `src/common/io.zig` | IO context helpers |
| [Compression](/api/compression) | `src/compression/` | gzip/deflate/brotli/zstd compress/decompress |
| [Cache](/api/cache) | — | ETag/conditional static serving, download resume |
| [Metrics](/api/metrics) | `src/web/metrics/` | Thread-safe request/response metrics |
| [Session](/api/session) | — | Cookie-backed sessions (no built-in store) |
| [SSE](/api/sse) | `src/web/sse/` | Server-Sent Events parsing and streaming |

## Quick Reference

### Encoding

- `httpx.quic.varint.encode(buf, value)` / `httpx.quic.varint.decode(data, offset)` — QUIC variable-length integer encoding

### WebSocket

See [Protocol API](/api/protocol) for the full WebSocket section:

- `httpx.websocket.Handshake.computeAccept(key, out)` — `Sec-WebSocket-Accept`
- `httpx.websocket.Handshake.buildUpgradeRequest(...)` — client upgrade head
- `httpx.websocket.Frame.buildFrameHeader / parseFrameHeader / applyMask / generateKey`
- `httpx.websocket.Frame.Opcode` — frame opcode enum

### MIME and URIs

- `httpx.mime.fromPath(path)` — extension-based MIME lookup
- `httpx.Uri.parse(...)` — RFC 3986 URI parsing
- `httpx.fs.readFileLimited(allocator, path, maxBytes)` — bounded file reads
