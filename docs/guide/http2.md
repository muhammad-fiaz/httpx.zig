# HTTP/2 Protocol

httpx.zig provides a complete, from-scratch implementation of HTTP/2 (RFC 9113) including HPACK header compression (RFC 7541). This guide covers high-level client/server runtime usage and low-level HTTP/2 protocol features.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/2 support. **httpx.zig implements HTTP/2 entirely from scratch**, following RFC 9113 and RFC 7541 specifications, including:
- **HPACK** header compression (RFC 7541) with `Without Indexing` / `Never Indexed` security for HTTP/2
- **HTTP/2** stream multiplexing, flow control (WINDOW_UPDATE), SETTINGS enforcement, GOAWAY/RST_STREAM, PRIORITY, CONTINUATION frames, PING, and connection pooling (RFC 9113)
- **ALPN** negotiation (RFC 7301) for automatic HTTP/2 and HTTP/3 protocol selection with HTTP/1.1 fallback
:::

## Platform Support

HTTP/2 support is validated across Linux, Windows, and macOS targets:

| Platform | Architecture | Status |
|----------|--------------|--------|
| Linux    | x86_64, aarch64, x86 | ✅ |
| Windows  | x86_64, aarch64, x86 | ✅ |
| macOS    | x86_64, aarch64 | ✅ |

## Features

- **High-level Client Runtime** - `Client` negotiates HTTP/2 over TLS via ALPN
  when `http2 = true` (default `false`; HTTP/1.x default `true`)
- **High-level Server Runtime** - `Server` serves HTTP/2 when `http2 = true`
  (default `true`). TLS deployments must configure ALPN to select `h2`; the
  server's default ALPN list does not include HTTP/2.
- **HPACK Header Compression** - Full RFC 7541 implementation with static and dynamic tables
- **Stream Multiplexing** - The server keeps one state per concurrent stream and
  answers them independently; the transport client can keep several requests in
  flight on one connection (`beginRequest` / `awaitResponse`). The high-level
  `Client` hands out pooled connections exclusively, so it still runs one
  exchange at a time per connection.
- **Flow Control** - Per-stream and connection-level flow control with WINDOW_UPDATE.
  The connection window is the fixed 65535 bytes of RFC 9113 Section 6.9.2;
  `SETTINGS_INITIAL_WINDOW_SIZE` only affects stream windows.
- **Stream Priority** - PRIORITY frames are parsed and tolerated; priority-based
  scheduling is not implemented.
- **Frame Encoding/Decoding** - Core HTTP/2 frame types are encoded and decoded;
  this does not imply complete extension-frame interoperability. Fixed-length
  violations produce connection or stream `FRAME_SIZE_ERROR` as the RFC requires.
- **CONTINUATION Frames** - Header blocks exceeding `MAX_FRAME_SIZE` are automatically split across HEADERS + CONTINUATION frames
- **SETTINGS Enforcement** - Peer `MAX_CONCURRENT_STREAMS`, `MAX_FRAME_SIZE`, and `INITIAL_WINDOW_SIZE` values are parsed and enforced; repeated settings are applied in order
- **GOAWAY/RST_STREAM** - Graceful connection shutdown and stream cancellation
  with proper error codes. A GOAWAY's last-stream-id never increases, refused
  client streams are reset, and new streams are blocked once either side sends
  or receives GOAWAY. A malformed header list is answered with a stream error
  (`RST_STREAM`), not a connection error.
- **HPACK Security** - `Without Indexing` / `Never Indexed` representations for volatile headers like `Authorization` and `Cookie`; those values never enter the dynamic table
- **Trailer Support** - Trailers are parsed and framed by the session layer;
  the one-shot `Client`/`Server` API does not surface them to handlers yet
  (see below)
- **Message Semantics** - Informational (1xx) responses, `content-length`
  validation, HEAD/204/205/304 body rules, CONNECT requests, and
  `END_STREAM`-terminated trailers are enforced in both directions.
  Request `:authority` is surfaced as `host` when no explicit host field is
  present; the high-level server answers unsupported methods with `501`.
- **Strict Header Validation** - Field names are lowercased, connection-specific
  fields are dropped, and malformed pseudo-header sets are rejected per
  RFC 9113 Section 8
- **Connection Preface Timeout** - Detects missing initial SETTINGS frame from peer
- **ALPN Negotiation** - The client offers `h2` for explicit HTTP/2 requests;
  the server selects it only when configured to do so.
- **Connection Pooling** - HTTP/1.x keep-alive and HTTP/2 sessions can be
  reused across sequential requests.

### Not implemented

- **Server push** - The client advertises `ENABLE_PUSH=0`; a `PUSH_PROMISE`
  frame is a connection error (RFC 9113 Section 8.4).
- **Priority-based scheduling** - `PRIORITY` is accepted and ignored.
- **Extended CONNECT** (`:protocol`, RFC 8441) is not enabled. The pseudo-header
  set is validated structurally, then rejected because
  `SETTINGS_ENABLE_CONNECT_PROTOCOL` is never advertised.


## High-level Client Usage

Enable HTTP/2 in `ClientConfig`:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var client = httpx.Client.init(allocator, io, .{
    .http2 = true,
});
defer client.deinit();

var res = try client.get("https://example.com/", .{});
defer res.deinit();

std.debug.print("version={s} status={d}\n", .{ res.version.wireNameResolved(), res.status });
```

::: tip TLS & ALPN Protocol Negotiation
Explicit `.http2` for an `https://` URL runs the native TLS client:
it offers `h2` via ALPN, verifies the server chain and hostname, and
fails loudly with `AlpnNegotiationFailed` when the server does not
select `h2` — never silently downgraded. The std TLS wrapper (no ALPN
hook) remains the transport for plain HTTPS/1.1 requests.
:::

## High-level Server Usage

Enable HTTP/2 in `ServerConfig`:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.server.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .http2 = true,
});
defer server.deinit();

try server.get("/h2", struct {
    fn handler(ctx: *httpx.web.router.Context) !httpx.web.router.Response {
        return ctx.text("hello from http2 server runtime");
    }
}.handler);

server.run();
```

## HPACK Header Compression

HPACK provides efficient header compression using static and dynamic tables.

### Encoding Headers

```zig
const httpx = @import("httpx");

var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Encoder with a dynamic table (peer SETTINGS_HEADER_TABLE_SIZE via applySettingsSize).
var enc = httpx.protocols.http2.hpack.Encoder.init(allocator);
defer enc.deinit();

var block = std.ArrayList(u8).empty;
defer block.deinit(allocator);

// Incremental indexing stores reusable fields; never-indexed keeps secrets
// like Authorization/Cookie out of the dynamic table (see HPACK Security below).
try enc.encode(&block, ":method", "GET", .incremental, false);
try enc.encode(&block, ":path", "/api/users", .incremental, false);
try enc.encode(&block, "accept", "application/json", .incremental, false);
try enc.encode(&block, "authorization", "Bearer <token>", .never, false);

std.debug.print("Encoded 4 headers into {d} bytes\n", .{block.items.len});
```

### Decoding Headers

```zig
var dec = httpx.protocols.http2.hpack.Decoder.init(allocator);
defer dec.deinit();

const res = try dec.decode(block.items);
defer {
    for (res.fields) |f| {
        allocator.free(f.name);
        allocator.free(f.value);
    }
    allocator.free(res.fields);
}

for (res.fields) |h| {
    std.debug.print("{s}: {s}\n", .{ h.name, h.value });
}
// res.totalSize tracks the decompressed list size for
// SETTINGS_MAX_HEADER_LIST_SIZE enforcement.
```

Integer coding (RFC 7541 Section 5.1) and Huffman coding live in
`src/protocols/common/integer.zig` and `src/protocols/common/huffman.zig`;
the RFC 7541 Appendix C vectors are covered by unit tests in
`src/protocols/http2/hpack.zig`.

## Stream Management

HTTP/2 uses streams to multiplex requests/responses.

### Creating Streams

```zig
// Streams are owned by httpx.protocols.http2.Session; client-initiated
// streams use odd IDs (1, 3, 5, ...). The per-stream state machine is
// httpx.protocols.http2.Stream (states: idle/reserved/open/half-closed/closed).
var st = httpx.protocols.http2.Stream.init(allocator, 1);
defer st.deinit();
```

### Stream States

HTTP/2 streams follow a state machine:

```
                         +--------+
                 send PP |        | recv PP
                ,--------|  idle  |--------.
               /         |        |         \
              v          +--------+          v
       +----------+          |           +----------+
       |          |          | send H /  |          |
,------| reserved |          | recv H    | reserved |------.
|      | (local)  |          |           | (remote) |      |
|      +----------+          v           +----------+      |
|          |             +--------+             |          |
|          |     recv ES |        | send ES     |          |
|   send H |     ,-------|  open  |-------.     | recv H   |
|          |    /        |        |        \    |          |
|          v   v         +--------+         v   v          |
|      +----------+          |           +----------+      |
|      |   half   |          |           |   half   |      |
|      |  closed  |          | send R /  |  closed  |      |
|      | (remote) |          | recv R    | (local)  |      |
|      +----------+          |           +----------+      |
|           |                |                 |           |
|           | send ES /      |       recv ES / |           |
|           | send R /       v        send R / |           |
|           | recv R     +--------+   recv R   |           |
| send R /  `----------->|        |<-----------'  send R / |
| recv R                 | closed |               recv R   |
`----------------------->|        |<-----------------------'
                         +--------+
```

```zig
var stream = httpx.protocols.http2.Stream.init(allocator, 1);
defer stream.deinit();

// Open stream (sending HEADERS)
try stream.onSendHeaders(false);

// Send END_STREAM flag
try stream.onSendData(true); // State: half-closed (local)

// Receive END_STREAM flag -> closed
try stream.onRecvData(true);
```

### Stream Priority

PRIORITY data travels in `httpx.protocols.http2.frame.Priority`
(`exclusive`, `streamDep`, `weight`); HEADERS frames can also carry it
(see `httpx.protocols.http2.frame.Headers`). Priority is advisory — the runtime
currently favors correctness (fair delivery) over strict weighted scheduling:

```zig
const prio = httpx.protocols.http2.frame.Priority{
    .exclusive = false,
    .streamDep = 0, // Root stream
    .weight = 32,
};
```

## HTTP/2 Framing

### Frame Header

Every HTTP/2 frame has a 9-byte header:

```
+-----------------------------------------------+
|                 Length (24)                   |
+---------------+---------------+---------------+
|   Type (8)    |   Flags (8)   |
+-+-------------+---------------+-------------------------------+
|R|                 Stream Identifier (31)                      |
+=+=============================================================+
|                   Frame Payload (0...)                      ...
+---------------------------------------------------------------+
```

```zig
// Parse a 9-byte frame header from the wire.
var hdr_buf: [httpx.protocols.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
// ... read 9 bytes into hdr_buf ...
const hdr = httpx.protocols.http2.FrameHeader.parse(&hdr_buf);
// hdr.length (u24), hdr.frameType (.headers/.data/...), hdr.flags, hdr.streamId (u31)

// Frame payload shapes live in httpx.protocols.http2.frame (Data, Headers, RstStream,
// Ping, Goaway, WindowUpdate, ...); connection and stream state machines in
// httpx.protocols.http2.connection (Session) and httpx.protocols.http2.stream (Stream).
// Most applications never touch these: use httpx.server.Server / httpx.Client or
// the examples below.
```

### Frame Types

| Type | Value | Description |
|------|-------|-------------|
| DATA | 0x00 | Request/response body |
| HEADERS | 0x01 | Header block |
| PRIORITY | 0x02 | Stream priority |
| RST_STREAM | 0x03 | Stream termination |
| SETTINGS | 0x04 | Connection parameters |
| PUSH_PROMISE | 0x05 | Server push |
| PING | 0x06 | Connectivity check |
| GOAWAY | 0x07 | Connection shutdown |
| WINDOW_UPDATE | 0x08 | Flow control |
| CONTINUATION | 0x09 | Header continuation |

### Building Frame Payloads

Frame payloads are plain structs in `httpx.protocols.http2.frame`:

```zig
// RST_STREAM carries an error code (see httpx.protocols.http2.ErrorCode).
const rst = httpx.protocols.http2.frame.RstStream{ .errorCode = @intFromEnum(httpx.protocols.http2.ErrorCode.cancel) };

// WINDOW_UPDATE carries a 31-bit increment.
const wu = httpx.protocols.http2.frame.WindowUpdate{ .increment = 32768 };

// PING carries 8 opaque bytes.
const ping = httpx.protocols.http2.frame.Ping{ .opaqueData = .{ 1, 2, 3, 4, 5, 6, 7, 8 } };

// HEADERS bodies are HPACK blocks produced with httpx.protocols.http2.hpack.Encoder
// (see HPACK section above).
```

## Flow Control

HTTP/2 uses flow control to prevent overwhelming receivers.

### Window Sizes

Per-stream windows live on `httpx.protocols.http2.Stream`
(`sendWindow`/`recvWindow`, default 65535 per RFC 9113); the connection-level
window lives on `httpx.protocols.http2.Session`. The runtime enforces them
automatically — the snippet below shows the accounting shape:

```zig
// Default window size: 65535 bytes (RFC 9113)
std.debug.print("Stream send window: {d}\n", .{stream.sendWindow});

// After sending data / receiving WINDOW_UPDATE the session adjusts the
// windows and returns an error on flow-control violations.
```

### Parsing WINDOW_UPDATE

`WINDOW_UPDATE` bodies decode to `httpx.protocols.http2.frame.WindowUpdate{ .increment }`
(a 31-bit value; zero is a connection `PROTOCOL_ERROR` on stream 0 and a stream
`PROTOCOL_ERROR` otherwise).

## Error Codes

HTTP/2 defines error codes for RST_STREAM and GOAWAY frames:

| Code | Value | Description |
|------|-------|-------------|
| NO_ERROR | 0x0 | Graceful shutdown |
| PROTOCOL_ERROR | 0x1 | Protocol violation |
| INTERNAL_ERROR | 0x2 | Implementation error |
| FLOW_CONTROL_ERROR | 0x3 | Flow control violation |
| SETTINGS_TIMEOUT | 0x4 | Settings not acknowledged |
| STREAM_CLOSED | 0x5 | Frame on closed stream |
| FRAME_SIZE_ERROR | 0x6 | Invalid frame size |
| REFUSED_STREAM | 0x7 | Stream refused |
| CANCEL | 0x8 | Stream cancelled |
| COMPRESSION_ERROR | 0x9 | HPACK decompression failure |
| CONNECT_ERROR | 0xa | CONNECT method failure |
| ENHANCE_YOUR_CALM | 0xb | Rate limiting |
| INADEQUATE_SECURITY | 0xc | TLS requirements not met |
| HTTP_1_1_REQUIRED | 0xd | HTTP/1.1 required |

## CONTINUATION Frames

When header blocks exceed `MAX_FRAME_SIZE`, `httpx.protocols.http2.Session`
automatically splits them across HEADERS + CONTINUATION frames on send
(`sendHeaders`/`sendHeaderBlock`) and reassembles them on receipt before
invoking the header callback — applications only ever see complete blocks.

## SETTINGS Enforcement

Peer SETTINGS values are stored on the session and enforced:

```zig
// Our limits (sent to the peer) and the peer's limits (enforced locally).
session.localSettings.maxConcurrentStreams = 100;
session.localSettings.maxFrameSize = 16384;

// The HPACK encoder tracks the peer's header table size:
// encoder.applySettingsSize(peer_header_table_size) on SETTINGS receipt.
```

Oversized frames, too many concurrent streams, and unknown SETTINGS
identifiers are rejected with connection errors (`FRAME_SIZE_ERROR` /
`PROTOCOL_ERROR`); see `httpx.protocols.http2.frame.validateSetting.

## GOAWAY and RST_STREAM

Both sending and receiving are supported via the session:

```zig
// RST_STREAM a single stream (e.g. cancel).
try session.sendRstStream(1, .cancel);

// Connection-level shutdown (GOAWAY + debug data).
try session.sendConnectionClose(.no_error, "server shutting down");
```

`ErrorCode` variants live in `httpx.protocols.http2` (`.no_error`,
`.protocol_error`, `.cancel`, ...).

## HPACK Security: Without Indexing / Never Indexed

For volatile headers like `Authorization` and `Cookie`, use non-indexing representations to prevent HPACK bomb attacks:

```zig
var enc = httpx.protocols.http2.hpack.Encoder.init(allocator);
defer enc.deinit();

// Without Indexing: don't add to dynamic table
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);
try enc.encode(&out, "Authorization", "Bearer token123", .without, false);

// Never Indexed: explicitly tell the decoder to never index
var out2 = std.ArrayList(u8).empty;
defer out2.deinit(allocator);
try enc.encode(&out2, "Cookie", "session=abc123", .never, false);
```

::: tip Security Note
Using incremental indexing for `Authorization` or `Cookie` headers can pollute the dynamic table and enable HPACK bomb attacks. Always use `Without Indexing` or `Never Indexed` for sensitive headers.
:::

## Trailer Support

HTTP/2 trailers (HEADERS after DATA with `END_STREAM`) are parsed by
`httpx.protocols.http2.Session` like any other header block. They must carry
`END_STREAM`, appear only once, and may not contain pseudo-headers or
`content-length`; violations reset the stream. A trailer block without
`END_STREAM` is a `PROTOCOL_ERROR`, not a second header block.

The high-level `httpx.server.Server`/`httpx.Client` one-shot API does not yet surface
trailers — use the `httpx.protocols.http2.transport` stream APIs directly if you need
them (see `examples/http2Multiplex.zig` for the runtime path).

## Connection Preface Timeout

Both client and server detect if the peer never sends its initial SETTINGS frame after the connection preface, preventing indefinite hangs.

## Running the Example

Run the client and multiplexing examples with:

```bash
zig build run-http2-client
zig build run-http2-multiplex
```

## See Also

- [Protocol API Reference](/api/protocol) - Full API documentation
- [HTTP/3 Guide](/guide/http3) - QPACK and QUIC support
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) - HTTP/2 specification
- [RFC 7541](https://tools.ietf.org/html/rfc7541) - HPACK specification
