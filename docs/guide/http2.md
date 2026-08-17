# HTTP/2 Protocol

httpx.zig provides a complete, from-scratch implementation of HTTP/2 (RFC 7540) including HPACK header compression (RFC 7541). This guide covers high-level client/server runtime usage and low-level HTTP/2 protocol features.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/2 support. **httpx.zig implements HTTP/2 entirely from scratch**, following RFC 7540 and RFC 7541 specifications.
:::

## Platform Support

HTTP/2 support is validated across Linux, Windows, and macOS targets:

| Platform | Architecture | Status |
|----------|--------------|--------|
| Linux    | x86_64, aarch64, x86 | ✅ |
| Windows  | x86_64, aarch64, x86 | ✅ |
| macOS    | x86_64, aarch64 | ✅ |

## Features

- **High-level Client Runtime** - `Client` can execute requests over HTTP/2 when `http2_enabled = true`
- **High-level Server Runtime** - `Server` can serve routes over HTTP/2 when `http2_enabled = true`
- **HPACK Header Compression** - Full RFC 7541 implementation with static and dynamic tables
- **Stream Multiplexing** - Multiple concurrent streams over a single connection
- **Flow Control** - Per-stream and connection-level flow control with WINDOW_UPDATE
- **Stream Priority** - Dependency-based prioritization
- **Frame Encoding/Decoding** - All HTTP/2 frame types supported
- **CONTINUATION Frames** - Header blocks exceeding `MAX_FRAME_SIZE` are automatically split across HEADERS + CONTINUATION frames
- **SETTINGS Enforcement** - Peer `MAX_CONCURRENT_STREAMS`, `MAX_FRAME_SIZE`, and `INITIAL_WINDOW_SIZE` values are parsed and enforced
- **GOAWAY/RST_STREAM** - Graceful connection shutdown and stream cancellation with proper error codes
- **HPACK Security** - `Without Indexing` / `Never Indexed` representations for volatile headers like `Authorization` and `Cookie`
- **Trailer Support** - Server sends trailers via `sendHttp2Trailers()`; client decodes trailers after END_STREAM
- **Connection Preface Timeout** - Detects missing initial SETTINGS frame from peer
- **ALPN Negotiation** - Client and server advertise `["h2", "http/1.1"]` during TLS handshake
- **Connection Pooling** - HTTP/2 connections are pooled and reused across requests

## High-level Client Usage

Enable HTTP/2 in `ClientConfig`:

```zig
var client = httpx.Client.initWithConfig(allocator, .{
    .http2_enabled = true,
    .http2_settings = .{
        .max_frame_size = 16 * 1024,
        .max_concurrent_streams = 100,
    },
});
defer client.deinit();

var res = try client.get("https://example.com/", .{});
defer res.deinit();

std.debug.print("version={s} status={d}\n", .{ res.version.toString(), res.status.code });
```

::: tip TLS & ALPN Protocol Negotiation
httpx.zig natively performs ALPN protocol negotiation via a post-handshake HTTP/2 preface probe on TLS connections when `http2_enabled = true` or when using `TlsConfig.withH2()`. If the server supports HTTP/2, the connection uses HTTP/2; otherwise it cleanly falls back to HTTP/1.1 without dropping data.
:::

## High-level Server Usage

Enable HTTP/2 in `ServerConfig`:

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
    .http2_enabled = true,
});
defer server.deinit();

try server.get("/h2", struct {
    fn handler(ctx: *httpx.Context) !httpx.Response {
        return ctx.text("hello from http2 server runtime");
    }
}.handler);

try server.listen();
```

## HPACK Header Compression

HPACK provides efficient header compression using static and dynamic tables.

### Encoding Headers

```zig
const httpx = @import("httpx");

var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Initialize HPACK context
var ctx = httpx.HpackContext.init(allocator);
defer ctx.deinit();

// Define headers
const headers = [_]httpx.hpack.HeaderEntry{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":path", .value = "/api/users" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "api.example.com" },
    .{ .name = "accept", .value = "application/json" },
};

// Encode using HPACK
const encoded = try httpx.hpack.encodeHeaders(&ctx, &headers, allocator);
defer allocator.free(encoded);

std.debug.print("Encoded {d} headers into {d} bytes\n", .{headers.len, encoded.len});
```

### Decoding Headers

```zig
var decode_ctx = httpx.HpackContext.init(allocator);
defer decode_ctx.deinit();

const decoded = try httpx.hpack.decodeHeaders(&decode_ctx, encoded, allocator);
defer {
    for (decoded) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(decoded);
}

for (decoded) |h| {
    std.debug.print("{s}: {s}\n", .{ h.name, h.value });
}
```

### Integer Encoding (RFC 7541 Section 5.1)

```zig
// Encode integer with prefix
var buf: [10]u8 = undefined;
const len = try httpx.hpack.encodeInteger(1337, 5, &buf);

// Decode integer
const result = try httpx.hpack.decodeInteger(buf[0..len], 5);
std.debug.print("Value: {d}\n", .{result.value});
```

## Stream Management

HTTP/2 uses streams to multiplex requests/responses.

### Creating Streams

```zig
// Client-side: uses odd stream IDs (1, 3, 5, ...)
var manager = httpx.StreamManager.init(allocator, true);
defer manager.deinit();

const stream1 = try manager.createStream(); // ID: 1
const stream2 = try manager.createStream(); // ID: 3
const stream3 = try manager.createStream(); // ID: 5
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
const stream = try manager.createStream();

// Open stream (sending HEADERS)
try stream.open();

// Send END_STREAM flag
stream.sendEndStream(); // State: half_closed_local

// Receive END_STREAM flag
stream.receiveEndStream(); // State: closed
```

### Stream Priority

```zig
const priority = httpx.StreamPriority{
    .dependency = 0, // Root stream
    .weight = 32,    // 1-256
    .exclusive = false,
};

stream.priority = priority;
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
const frame_header = httpx.Http2FrameHeader{
    .length = 100,
    .frame_type = .headers,
    .flags = 0x04, // END_HEADERS
    .stream_id = 1,
};

const serialized = frame_header.serialize(); // 9 bytes
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

```zig
// RST_STREAM frame
const rst_payload = httpx.stream.buildRstStreamPayload(.no_error);

// WINDOW_UPDATE frame
const window_update = httpx.stream.buildWindowUpdatePayload(32768);

// GOAWAY frame
const goaway = try httpx.stream.buildGoawayPayload(0, .no_error, null, allocator);
defer allocator.free(goaway);

// PING frame
const ping = httpx.stream.buildPingPayload(.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });

// HEADERS frame with HPACK-encoded headers
const headers_result = try httpx.stream.buildHeadersFramePayload(
    &stream_manager,
    &[_]httpx.hpack.HeaderEntry{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/api/data" },
    },
    null, // No priority
    allocator,
);
defer allocator.free(headers_result.payload);
```

## Flow Control

HTTP/2 uses flow control to prevent overwhelming receivers.

### Window Sizes

```zig
// Default window size: 65535 bytes (RFC 7540)
std.debug.print("Stream send window: {d}\n", .{stream.send_window});
std.debug.print("Connection send window: {d}\n", .{manager.connection_send_window});

// After sending data
const data_size: i32 = 16384;
stream.send_window -= data_size;
manager.connection_send_window -= data_size;

// After receiving WINDOW_UPDATE
const increment: i32 = 32768;
stream.send_window += increment;
manager.connection_send_window += increment;
```

### Parsing WINDOW_UPDATE

```zig
const wu_payload = httpx.stream.buildWindowUpdatePayload(65535);
const parsed_increment = try httpx.stream.parseWindowUpdatePayload(&wu_payload);
```

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

When header blocks exceed `MAX_FRAME_SIZE`, httpx.zig automatically splits them across HEADERS + CONTINUATION frames:

```zig
// Headers are automatically split when they exceed max_frame_size
const frames = try httpx.stream.buildHeadersAndContinuations(
    &stream_manager,
    1, // stream_id
    &headers,
    null, // priority (optional)
    16384, // max_frame_size
    false, // end_stream
    allocator,
);
defer allocator.free(frames);
// frames is a flat buffer of complete HTTP/2 frames ready to write
```

## SETTINGS Enforcement

Peer SETTINGS values are parsed and enforced:

```zig
// Apply peer settings
const settings = httpx.Http2Settings{
    .max_concurrent_streams = 100,
    .max_frame_size = 16384,
    .initial_window_size = 65535,
};
try manager.applyPeerSettings(settings);

// Check before opening streams
if (!manager.canOpenStream()) {
    std.debug.print("Max concurrent streams reached\n", .{});
}

// Validate frame sizes
manager.validateFrameSize(frame_length) catch |err| {
    std.debug.print("Frame too large for peer: {}\n", .{err});
};
```

## GOAWAY and RST_STREAM

Both sending and receiving are supported:

```zig
// Build GOAWAY frame for clean shutdown
const goaway = try httpx.stream.buildGoawayFrame(
    last_stream_id,
    .no_error,
    "server shutting down",
    allocator,
);
defer allocator.free(goaway);

// Build RST_STREAM frame to cancel a specific stream
const rst = httpx.stream.buildRstStreamFrame(1, .cancel);
```

## HPACK Security: Without Indexing / Never Indexed

For volatile headers like `Authorization` and `Cookie`, use non-indexing representations to prevent HPACK bomb attacks:

```zig
// Without Indexing: don't add to dynamic table
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);
try httpx.hpack.encodeHeaderWithoutIndexing(
    null, "Authorization", "Bearer token123", allocator, &out,
);

// Never Indexed: explicitly tell decoder to never index
var out2 = std.ArrayList(u8).empty;
defer out2.deinit(allocator);
try httpx.hpack.encodeHeaderNeverIndexed(
    null, "Cookie", "session=abc123", allocator, &out2,
);
```

::: tip Security Note
Using incremental indexing for `Authorization` or `Cookie` headers can pollute the dynamic table and enable HPACK bomb attacks. Always use `Without Indexing` or `Never Indexed` for sensitive headers.
:::

## Trailer Support

Servers can send HTTP/2 trailers after the response body:

```zig
fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    var resp = ctx.text("hello");
    // Send trailers after the response body
    try resp.sendHttp2Trailers(&.{
        .{ "x-checksum", "abc123" },
    });
    return resp;
}
```

Client receives trailers in the `Response.trailers` field after the response body is fully read.

## Connection Preface Timeout

Both client and server detect if the peer never sends its initial SETTINGS frame after the connection preface, preventing indefinite hangs.

## Running the Example

Run the low-level protocol, high-level runtime, and advanced HTTP/2 examples with:

```bash
zig build run-all-http2_example
./zig-out/bin/http2_example

zig build run-all-http2_client_runtime
zig build run-all-http2_server_runtime
zig build run-all-http2_advanced
```

## See Also

- [Protocol API Reference](/api/protocol) - Full API documentation
- [HTTP/3 Guide](/guide/http3) - QPACK and QUIC support
- [RFC 7540](https://tools.ietf.org/html/rfc7540) - HTTP/2 specification
- [RFC 7541](https://tools.ietf.org/html/rfc7541) - HPACK specification
