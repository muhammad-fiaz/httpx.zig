# Protocol API

Low-level protocol framing, parsing, and header compression. This module provides complete implementations of HTTP/1.1 parsing, HTTP/2 framing with HPACK, and HTTP/3 framing with QPACK over QUIC transport.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/2, HTTP/3, or QUIC support. **httpx.zig implements these protocols entirely from scratch**. This includes complete implementations of HPACK, QPACK, HTTP/2 framing, HTTP/3 framing, and QUIC transport as specified in the relevant RFCs.
:::

## Protocol Support Matrix

| Protocol | Version | Status | RFC | Notes |
|----------|---------|--------|-----|-------|
| HTTP/1.0 | 1.0 | ✅ Full | RFC 1945 | High-level runtime support |
| HTTP/1.1 | 1.1 | ✅ Full | RFC 7230-7235 | High-level runtime support |
| HTTP/2 | h2 | ✅ Full | RFC 7540, RFC 7541 | Full protocol-module implementation (framing/stream state/flow control/HPACK), integrated with high-level client/server runtimes |
| HTTP/3 | h3 | ✅ Full | RFC 9114, RFC 9204 | Full protocol-module implementation (framing/QPACK/QUIC helpers), integrated with high-level client/server runtimes |
| QUIC | v1 | ✅ Full | RFC 9000 | QUIC transport/frame primitives implemented in protocol module |

## HTTP/1.1 Parser

### Parser

A state-machine based HTTP/1.1 parser for both requests and responses.

```zig
const httpx = @import("httpx");

var parser = httpx.Parser.init(allocator);
defer parser.deinit();

// Feed data incrementally
const bytes_consumed = try parser.feed(incoming_data);

// Check if parsing is complete
if (parser.isComplete()) {
    const method = parser.getMethod();
    const path = parser.getPath();
    const headers = parser.getHeaders();
    const body = parser.getBody();
}

// Reset for next request
parser.reset();
```

### Parser Methods

| Method | Description |
|--------|-------------|
| `init(allocator)` | Creates a new parser |
| `feed(data)` | Feeds data, returns bytes consumed |
| `isComplete()` | Returns true when message is complete |
| `getMethod()` | Returns HTTP method string |
| `getPath()` | Returns request path |
| `getHeaders()` | Returns parsed headers |
| `getBody()` | Returns message body |
| `reset()` | Resets for next message |
| `finishEof()` | Marks complete on connection close |

### Chunked Transfer Encoding

```zig
// Parser handles chunked encoding automatically
const parser = httpx.Parser.init(allocator);

// Feed chunked data
_ = try parser.feed("HTTP/1.1 200 OK\r\n");
_ = try parser.feed("Transfer-Encoding: chunked\r\n\r\n");
_ = try parser.feed("5\r\nHello\r\n");
_ = try parser.feed("6\r\n World\r\n");
_ = try parser.feed("0\r\n\r\n");

// Body is automatically dechunked
const body = parser.getBody(); // "Hello World"
```

## HTTP/2 Support

httpx.zig provides full HTTP/2 protocol support including:
- HPACK header compression (RFC 7541)
- Stream state machine and multiplexing
- Flow control with WINDOW_UPDATE handling
- Frame encoding/decoding

### HTTP/2 Frame Types

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

### `Http2FrameHeader`

Parses and serializes HTTP/2 frame headers.

```zig
pub const Http2FrameHeader = struct {
    length: u24,
    frame_type: Http2FrameType,
    flags: u8,
    stream_id: u31,
    
    pub fn parse(bytes: [9]u8) Http2FrameHeader
    pub fn serialize(self: Http2FrameHeader) [9]u8
};

// Example: Parse incoming frame
var header_bytes: [9]u8 = undefined;
_ = try socket.recv(&header_bytes);
const header = httpx.Http2FrameHeader.parse(header_bytes);

// Read payload
var payload = try allocator.alloc(u8, header.length);
_ = try socket.recv(payload);
```

### `Http2Connection`

Manages HTTP/2 framing and the connection preface/settings.

```zig
const httpx = @import("httpx");

var conn = httpx.Http2Connection.init(socket, allocator);
defer conn.deinit();

// Perform HTTP/2 handshake
try conn.handshake();

// Send a frame
const header = httpx.Http2FrameHeader{
    .length = @intCast(payload.len),
    .frame_type = .headers,
    .flags = 0x04, // END_HEADERS
    .stream_id = 1,
};
try conn.writeFrame(header, payload);

// Read a frame
const frame = try conn.readFrame(allocator, 16384);
```

### Http2Connection Methods

| Method | Description |
|--------|-------------|
| `handshake()` | Sends client preface + SETTINGS |
| `readFrame(allocator, max_size)` | Reads next frame |
| `writeFrame(header, payload)` | Writes a frame |
| `sendSettings(settings)` | Sends SETTINGS frame |
| `sendPing(data)` | Sends PING frame |
| `sendGoaway(last_id, error_code)` | Sends GOAWAY |

### HPACK Header Compression

#### `HpackContext`

HPACK encoder/decoder context managing static and dynamic tables (RFC 7541).

```zig
const httpx = @import("httpx");

var ctx = httpx.HpackContext.init(allocator);
defer ctx.deinit();

// Encode headers
const headers = [_]httpx.hpack.HeaderEntry{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = "accept", .value = "text/html" },
};
const encoded = try httpx.encodeHpackHeaders(&ctx, &headers, allocator);
defer allocator.free(encoded);

// Decode headers
const decoded = try httpx.decodeHpackHeaders(&ctx, encoded_data, allocator);
defer {
    for (decoded) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(decoded);
}
```

#### HPACK Static Table (Partial)

| Index | Name | Value |
|-------|------|-------|
| 1 | :authority | |
| 2 | :method | GET |
| 3 | :method | POST |
| 4 | :path | / |
| 5 | :path | /index.html |
| 6 | :scheme | http |
| 7 | :scheme | https |
| 8 | :status | 200 |
| ... | ... | ... |

### `StreamManager`

Manages HTTP/2 stream state machine and flow control.

```zig
const httpx = @import("httpx");

var manager = httpx.StreamManager.init(allocator, true); // client mode
defer manager.deinit();

// Create a new stream
const stream_id = try manager.createStream();

// Get stream state
const state = manager.getStreamState(stream_id);

// Update flow control window
try manager.updateWindow(stream_id, 65535);

// Close stream
try manager.closeStream(stream_id);
```

#### Stream States

| State | Description |
|-------|-------------|
| `idle` | Initial state |
| `open` | Active stream |
| `half_closed_local` | Local side closed |
| `half_closed_remote` | Remote side closed |
| `closed` | Stream fully closed |

### SETTINGS Helpers

```zig
// Encode settings payload
var settings = httpx.Http2Settings{
    .header_table_size = 4096,
    .enable_push = false,
    .max_concurrent_streams = 100,
    .initial_window_size = 65535,
    .max_frame_size = 16384,
    .max_header_list_size = 8192,
};
const payload = try httpx.encodeSettingsPayload(&settings, allocator);

// Apply received settings
try httpx.applySettingsPayload(&settings, received_payload);
```

## HTTP/3 Support

httpx.zig provides HTTP/3 protocol support including:
- QPACK header compression (RFC 9204) 
- QUIC transport framing (RFC 9000)
- Variable-length integer encoding
- Stream and frame types

### HTTP/3 Frame Types

| Type | Description |
|------|-------------|
| DATA (0x00) | Request/response body |
| HEADERS (0x01) | Encoded headers |
| CANCEL_PUSH (0x03) | Cancel server push |
| SETTINGS (0x04) | Configuration |
| PUSH_PROMISE (0x05) | Server push |
| GOAWAY (0x07) | Graceful shutdown |
| MAX_PUSH_ID (0x0D) | Push limit |

### `Http3FrameHeader`

Encodes/decodes the HTTP/3 frame header (type + length), using QUIC varints.

```zig
const httpx = @import("httpx");

// Encode frame header
const header = httpx.Http3FrameHeader{
    .frame_type = .headers,
    .length = payload.len,
};
const encoded = try header.encode(allocator);

// Decode frame header
const decoded = try httpx.Http3FrameHeader.decode(data);
```

### QPACK Header Compression

#### `QpackContext`

QPACK encoder/decoder context for HTTP/3 header compression (RFC 9204).

```zig
const httpx = @import("httpx");

var ctx = httpx.QpackContext.init(allocator);
defer ctx.deinit();

// Encode headers
const headers = [_]httpx.qpack.HeaderEntry{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = ":path", .value = "/" },
};
const encoded = try httpx.encodeQpackHeaders(&ctx, &headers, allocator);
defer allocator.free(encoded);

// Decode headers
const decoded = try httpx.decodeQpackHeaders(&ctx, encoded_data, allocator);
```

### Variable-Length Integers

QUIC uses variable-length integer encoding for efficiency.

```zig
const httpx = @import("httpx");

// Encode varint
var buf: [8]u8 = undefined;
const len = try httpx.encodeVarInt(16384, &buf);
// Result: buf[0..len] contains encoded bytes

// Decode varint
const result = try httpx.decodeVarInt(data);
const value = result.value; // The decoded u62 value
const bytes_consumed = result.len;
```

#### VarInt Encoding Ranges

| Prefix Bits | First Byte | Range |
|-------------|------------|-------|
| 00 | 0x00-0x3F | 0 to 63 |
| 01 | 0x40-0x7F | 0 to 16,383 |
| 10 | 0x80-0xBF | 0 to 1,073,741,823 |
| 11 | 0xC0-0xFF | 0 to 4,611,686,018,427,387,903 |

## QUIC Transport

Low-level QUIC packet and frame handling for HTTP/3 transport.

### Connection ID

```zig
const httpx = @import("httpx");

// Create from bytes
const cid = try httpx.QuicConnectionId.init(&[_]u8{0x01, 0x02, 0x03, 0x04});

// Generate random
const random_cid = httpx.QuicConnectionId.random();

// Get length
const len = cid.len();
```

### Long Header Packets

Used for Initial, 0-RTT, Handshake, and Retry packets.

```zig
const httpx = @import("httpx");

const header = httpx.QuicLongHeader{
    .packet_type = .initial,
    .version = .v1,
    .dcid = dest_cid,
    .scid = source_cid,
};

// Encode
const encoded = try header.encode(allocator);

// Decode
const decoded = try httpx.QuicLongHeader.decode(packet_data);
```

### Short Header Packets

Used for application data after handshake completion.

```zig
const httpx = @import("httpx");

const header = httpx.QuicShortHeader{
    .dcid = dest_cid,
    .packet_number = 1234,
    .key_phase = false,
};
```

### QUIC Frame Types

| Type | Description |
|------|-------------|
| PADDING | Padding bytes |
| PING | Connection liveness |
| ACK | Acknowledgment |
| RESET_STREAM | Stream termination |
| STOP_SENDING | Request to stop sending |
| CRYPTO | Cryptographic handshake |
| NEW_TOKEN | Address validation token |
| STREAM | Application data |
| MAX_DATA | Connection flow control |
| MAX_STREAM_DATA | Stream flow control |
| MAX_STREAMS | Stream limit |
| DATA_BLOCKED | Flow control blocked |
| STREAM_DATA_BLOCKED | Stream blocked |
| NEW_CONNECTION_ID | New CID |
| RETIRE_CONNECTION_ID | Retire CID |
| PATH_CHALLENGE | Path validation |
| PATH_RESPONSE | Path validation response |
| CONNECTION_CLOSE | Close connection |
| HANDSHAKE_DONE | Handshake complete |

### STREAM Frame

```zig
const httpx = @import("httpx");

const frame = httpx.QuicStreamFrame{
    .stream_id = 4, // Client-initiated bidirectional
    .offset = 0,
    .fin = false,
    .data = "Hello, HTTP/3!",
};

// Encode
const encoded = try frame.encode(allocator);

// Decode  
const decoded = try httpx.QuicStreamFrame.decode(frame_data);
```

## Complete HTTP/2 Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect
    var socket = try httpx.Socket.create(.tcp);
    defer socket.close();
    
    const addr = try std.net.Address.resolveIp("example.com", 443);
    try socket.connect(addr);

    // HTTP/2 connection
    var conn = httpx.Http2Connection.init(socket, allocator);
    defer conn.deinit();
    
    try conn.handshake();

    // Encode headers
    var hpack = httpx.HpackContext.init(allocator);
    defer hpack.deinit();
    
    const headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
    };
    const encoded = try httpx.encodeHpackHeaders(&hpack, &headers, allocator);
    
    // Send HEADERS frame
    try conn.writeFrame(.{
        .length = @intCast(encoded.len),
        .frame_type = .headers,
        .flags = 0x05, // END_HEADERS | END_STREAM
        .stream_id = 1,
    }, encoded);

    // Read response
    while (true) {
        const frame = try conn.readFrame(allocator, 16384);
        if (frame.header.frame_type == .headers) {
            // Decode response headers
            const resp_headers = try httpx.decodeHpackHeaders(&hpack, frame.payload, allocator);
            // Process headers...
        } else if (frame.header.frame_type == .data) {
            std.debug.print("Body: {s}\n", .{frame.payload});
            if (frame.header.flags & 0x01 != 0) break; // END_STREAM
        }
    }
}
```

## See Also

- [Client API](/api/client) - High-level HTTP client
- [Server API](/api/server) - HTTP server implementation
- [Network API](/api/net) - TCP, UDP, TLS sockets
- [HTTP/2 Guide](/guide/http2) - HTTP/2 usage guide
- [HTTP/3 Guide](/guide/http3) - HTTP/3 usage guide
