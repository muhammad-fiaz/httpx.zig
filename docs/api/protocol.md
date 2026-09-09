# Protocol API

Low-level protocol framing, parsing, and header compression. This module provides HTTP/1.1 parsing, HTTP/2 framing with HPACK, and HTTP/3 framing with QPACK over QUIC transport primitives.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols from scratch**, including HPACK, QPACK, HTTP/2 framing, HTTP/3 framing, and QUIC transport frame coding as specified in the relevant RFCs.
:::

## Protocol Support Matrix

| Protocol | Version | Status | RFC | Notes |
|----------|---------|--------|-----|-------|
| HTTP/1.0 | 1.0 | ✅ Full | RFC 1945 | High-level runtime support |
| HTTP/1.1 | 1.1 | ✅ Full | RFC 9112 | High-level runtime support |
| HTTP/2 | h2 | ✅ Full | RFC 7540, RFC 7541 | Framing/stream state/flow control/HPACK plus high-level client/server runtimes |
| HTTP/3 | h3 | ✅ Full | RFC 9114, RFC 9204 | Framing/QPACK/QUIC helpers plus high-level client/server runtimes |
| QUIC | v1 | ✅ Primitives | RFC 9000 | Transport/frame coding primitives in the protocol module |

## HTTP/1.1 Parser (`httpx.http1.parser`)

Function-style parser over byte buffers:

```zig
// Request line + headers.
const head = try httpx.http1.parser.parseRequestHead(buf);
// head.method, head.path, head.minorVersion, head.majorVersion, head.headEnd
var fields: [128]httpx.http1.parser.Field = undefined;
const blk = try httpx.http1.parser.parseHeaderBlock(buf, head.headEnd, &fields);

// Framing decision (none / content_length / chunked / tunnel).
const framing = try httpx.http1.parser.decideFraming(fields[0..blk.count], false, 0, 0);

// Incremental chunked decoding.
var dec = httpx.http1.parser.ChunkedDecoder.init();
while (!dec.isDone()) {
    _ = try dec.decode(chunk);
}
```

Limits live in `httpx.http1.parser.Options` (`allowLfLineEndings`); size caps in
`DEFAULT_MAX_HEADER_BYTES`, `DEFAULT_MAX_BODY_BYTES`, `DEFAULT_MAX_HEADERS`.

## HTTP/2 Support (`httpx.http2`)

- HPACK header compression (RFC 7541)
- Stream state machine and multiplexing
- Flow control with WINDOW_UPDATE handling
- Frame encoding/decoding

### Frame Types

| Type | Value | Description |
|------|-------|-------------|
| DATA | 0x0 | Request/response body data |
| HEADERS | 0x1 | Header block fragment |
| PRIORITY | 0x2 | Stream priority |
| RST_STREAM | 0x3 | Stream termination |
| SETTINGS | 0x4 | Configuration parameters |
| PUSH_PROMISE | 0x5 | Server push |
| PING | 0x6 | Connection liveness |
| GOAWAY | 0x7 | Graceful shutdown |
| WINDOW_UPDATE | 0x8 | Flow control |
| CONTINUATION | 0x9 | Header continuation |

### Frames (`httpx.http2.frame`)

```zig
var hdrBuf: [httpx.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
const hdr = httpx.http2.frame.FrameHeader.parse(&hdrBuf);
var out: [9]u8 = undefined;
hdr.serialize(&out);

// Writers: writeHeader, writeData, writeRstStream, writeSettings,
// writeSettingsAck, writePing, writeWindowUpdate, writeGoaway,
// writePriority. Union decode via Frame.parse(hdr, payload, allocator).
```

### HPACK (`httpx.http2.hpack`)

```zig
var enc = httpx.http2.hpack.Encoder.init(allocator);
defer enc.deinit();
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);
try enc.encode(&out, ":method", "GET", .incremental, false);
try enc.encode(&out, ":path", "/", .incremental, false);

var dec = httpx.http2.hpack.Decoder.init(allocator);
defer dec.deinit();
const res = try dec.decode(out.items);
// res.fields: []HeaderField{name, value}
```

### Session (`httpx.http2.Session`)

```zig
var sess = try httpx.http2.Session.init(allocator, .client, .{});
defer sess.deinit();
try sess.startHandshake();
const sid = try sess.nextClientStreamId();
try sess.sendHeaders(sid, &fields, false);
_ = try sess.sendData(sid, body, true);
```

## HTTP/3 Support (`httpx.http3`)

- QPACK header compression (RFC 9204)
- QUIC transport framing (RFC 9000)
- Variable-length integer encoding
- Stream and frame types

### Frames (`httpx.http3.frame`)

```zig
var off: usize = 0;
const hdr = try httpx.http3.frame.parseFrameHeader(data, &off); // FrameHeader
const parsed = try httpx.http3.frame.parseFrame(data, &off);    // ParsedFrame
var buf: [16]u8 = undefined;
const n = try httpx.http3.frame.encodeFrameHeader(&buf, 0x01, payload.len);
// Settings payloads: parseSettingsPayload / buildSettingsPayload.
```

### Connection (`httpx.http3.Connection`)

```zig
var conn = httpx.http3.Connection.init(allocator, .client);
defer conn.deinit();
const ctrl = try conn.buildControlStream();
defer allocator.free(ctrl);
const streamId = conn.nextBidiStreamId();
var req = conn.createRequestStream(streamId);
const head = try req.buildRequestHeaders(allocator, &headers, false);
const data = try req.buildData(body);
```

### QPACK (`httpx.http3.qpack`)

Static/dynamic table header compression with encoder/decoder stream
instructions; see `src/protocols/http3/qpack.zig`.

## QUIC (`httpx.quic`)

Transport coding primitives (RFC 9000): `varint.encode` / `varint.decode`,
`packet`, `frames` (STREAM, CRYPTO, ACK, RESET_STREAM, STOP_SENDING, ...),
`connection`, `params` (transport parameters), `stream`, `crypto`,
`connectionId`, `path`, `transport`.

```zig
var buf: [8]u8 = undefined;
const n = try httpx.quic.varint.encode(&buf, 15293);
var off: usize = 0;
const v = try httpx.quic.varint.decode(&buf, &off);
```

## Complete HTTP/2 Example

See `examples/http2_client.zig` (h2c client + server) and
`examples/http2_multiplex.zig` (HPACK + multiplexed streams). For HTTP/3,
see `examples/http3_client.zig` and `examples/http3_quic.zig`.
