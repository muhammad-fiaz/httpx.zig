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
| macOS    | x86_64, aarch64, x86 | ✅ |

## Features

- **High-level Client Runtime** - `Client` can execute requests over HTTP/2 when `http2_enabled = true`
- **High-level Server Runtime** - `Server` can serve routes over HTTP/2 when `http2_enabled = true`
- **HPACK Header Compression** - Full RFC 7541 implementation with static and dynamic tables
- **Stream Multiplexing** - Multiple concurrent streams over a single connection
- **Flow Control** - Per-stream and connection-level flow control with WINDOW_UPDATE
- **Stream Priority** - Dependency-based prioritization
- **Frame Encoding/Decoding** - All HTTP/2 frame types supported

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

::: warning TLS Negotiation Note
The current Zig stdlib TLS API used by httpx.zig does not yet expose ALPN selection in the high-level client path. The HTTP/2 runtime sends HTTP/2 frames directly; endpoints that strictly require ALPN negotiation may reject the connection.
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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

## Running the Example

Run the low-level protocol and high-level runtime HTTP/2 examples with:

```bash
zig build example-http2_example
./zig-out/bin/http2_example

zig build run-http2_client_runtime
zig build run-http2_server_runtime
```

## See Also

- [Protocol API Reference](/api/protocol) - Full API documentation
- [HTTP/3 Guide](/guide/http3) - QPACK and QUIC support
- [RFC 7540](https://tools.ietf.org/html/rfc7540) - HTTP/2 specification
- [RFC 7541](https://tools.ietf.org/html/rfc7541) - HPACK specification
