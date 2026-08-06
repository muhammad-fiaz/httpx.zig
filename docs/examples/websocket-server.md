# WebSocket Server Example

Demonstrates WebSocket handshake detection, key extraction, accept key computation, frame encoding/decoding, and bidirectional messaging using the flat WebSocket API.

## Demo Program

```zig
// Detect WebSocket upgrade
const is_upgrade = httpx.isWebSocketUpgrade(&upgrade_req);

// Extract key and compute accept
const key = httpx.wsExtractKey(&upgrade_req);
const accept_key = try httpx.wsAcceptKey(key.?, allocator);

// Encode and decode frames
const text_frame = try httpx.wsTextFrame(allocator, "Hello!");
var decoded = try httpx.wsDecodeFrame(allocator, text_frame);

// Control frames
const ping = try httpx.wsPingFrame(allocator, "ping");
const pong = try httpx.wsPongFrame(allocator, "pong");
const close = try httpx.wsCloseFrame(allocator, .normal, "goodbye");

// Masked frame (client -> server)
const masked = try httpx.wsEncodeFrame(allocator, .text, "payload", true, true, mask_key);
```

## Run

```
zig build example-websocket-server
```

## Checklist

- [ ] `isWebSocketUpgrade` detects upgrade request
- [ ] `wsExtractKey` extracts `Sec-WebSocket-Key` header
- [ ] `wsAcceptKey` computes correct accept hash
- [ ] Text frames encode/decode roundtrip correctly
- [ ] Binary frames encode/decode roundtrip correctly
- [ ] Masked frames decode to unmasked payload
- [ ] Ping/Pong/Close control frames work
- [ ] Large payloads (>125 bytes) use extended length encoding
