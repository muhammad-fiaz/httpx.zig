# HTTP/3 Protocol

httpx.zig provides a complete, from-scratch implementation of HTTP/3 protocol primitives (RFC 9114) including QPACK header compression (RFC 9204) and QUIC transport framing (RFC 9000), plus high-level client/server runtime paths.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/3 or QUIC support. **httpx.zig implements these protocols entirely from scratch**, following RFC 9114, RFC 9204, and RFC 9000 specifications, including:
- **QPACK** header compression (RFC 9204) with static/dynamic tables and decoder/encoder stream instructions for HTTP/3
- **QUIC** transport frame encoding/decoding (RFC 9000) with RESET_STREAM/STOP_SENDING cancellation, version negotiation, and transport parameters
- **HTTP/3** frame types, SETTINGS, GOAWAY, and CONNECTION_CLOSE handling
- **Interop note:** strict TLS-in-QUIC server negotiation expectations may vary by endpoint deployment
:::

## Platform Support

HTTP/3 support is validated across Linux, Windows, and macOS targets:

| Platform | Architecture | Status |
|----------|--------------|--------|
| Linux    | x86_64, aarch64, x86 | ✅ |
| Windows  | x86_64, aarch64, x86 | ✅ |
| macOS    | x86_64, aarch64 | ✅ |

## Features

- **High-level Client Runtime** - `Client` can execute requests over HTTP/3 when `http3_enabled = true`
- **High-level Server Runtime** - `Server` can serve routes over HTTP/3 when `http3_enabled = true`
- **QPACK Header Compression** - Full RFC 9204 implementation with 99-entry static table
- **QUIC Transport Framing** - All QUIC frame types (STREAM, CRYPTO, ACK, etc.)
- **Variable-Length Integers** - QUIC varint encoding/decoding
- **Connection IDs** - Full connection ID management
- **Transport Parameters** - QUIC transport parameter encoding and decoding
- **Flow Control** - MAX_DATA and MAX_STREAM_DATA frame handling with connection-level and per-stream flow control windows
- **GOAWAY and CONNECTION_CLOSE** - Both client and server handle incoming GOAWAY gracefully and can send GOAWAY or CONNECTION_CLOSE on errors
- **Stream Cancellation** - RESET_STREAM and STOP_SENDING frames for graceful stream teardown without connection disruption
- **QPACK Decoder Stream** - Decode functions for Section Ack, Stream Cancel, Insert Count Increment, Set Capacity, and encoder stream instructions
- **Connection Preface Timeout** - Detects missing initial SETTINGS frame from peer

## High-level Client Usage

Enable HTTP/3 in `ClientConfig`:

```zig
var client = httpx.Client.initWithConfig(allocator, .{
    .http3_enabled = true,
    .http3_settings = .{
        .qpack_max_table_capacity = 4096,
        .qpack_blocked_streams = 16,
        .max_field_section_size = 8192,
        .enable_connect_protocol = true,
        .enable_datagrams = false,
    },
});
defer client.deinit();

var response = try client.get("http://127.0.0.1:8080/runtime", .{});
defer response.deinit();

std.debug.print("version={s} status={d}\n", .{ response.version.toString(), response.status.code });
```

You can also force HTTP/3 on a single request (without changing other client defaults):

```zig
var response = try client.get("http://127.0.0.1:8080/runtime", httpx.RequestOptions.defaults().withHttp3());
defer response.deinit();
```

::: warning Interoperability Note
The current HTTP/3 runtime paths use UDP + QUIC stream framing primitives directly. Interoperability with endpoints that require full TLS-in-QUIC handshake negotiation may vary by deployment requirements.
:::

## High-level Server Usage

Enable HTTP/3 in `ServerConfig`:

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = 8080,
    .http3_enabled = true,
    .http2_enabled = false,
});
defer server.deinit();

try server.get("/h3", struct {
    fn handler(ctx: *httpx.Context) !httpx.Response {
        return ctx.text("hello from http3 server runtime");
    }
}.handler);

try server.listen();
```

::: tip ALPN Default
When `http3_enabled = true`, the server automatically includes `"h3"` in the ALPN protocols list. The default `tls_alpn_protocols` is `&.{ "h3", "h2", "http/1.1" }`, so clients can negotiate HTTP/3, HTTP/2, or HTTP/1.1 automatically.
:::

## QPACK vs HPACK

QPACK is designed for HTTP/3's out-of-order delivery:

| Feature | HPACK (HTTP/2) | QPACK (HTTP/3) |
|---------|----------------|----------------|
| Static Table | 61 entries | 99 entries |
| Dynamic Table | Required in-order | Allows out-of-order |
| Blocking | Synchronous | Async with streams |
| Use Case | TCP (ordered) | QUIC (unordered) |

### QPACK Static Table

```zig
const httpx = @import("httpx");

// QPACK has a larger static table
std.debug.print("QPACK static table: {d} entries\n", .{httpx.qpack.StaticTable.entries.len}); // 99
std.debug.print("HPACK static table: {d} entries\n", .{httpx.hpack.StaticTable.entries.len}); // 61

// Common static table lookups
const idx = httpx.qpack.StaticTable.findNameValue(":method", "GET");
if (idx) |index| {
    std.debug.print("Found :method=GET at index {d}\n", .{index});
}
```

### QPACK Encoding

```zig
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var ctx = httpx.QpackContext.init(allocator);
defer ctx.deinit();

const headers = [_]httpx.qpack.HeaderEntry{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":path", .value = "/api/v3/resources" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "api.example.com" },
    .{ .name = "accept", .value = "application/json" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
};

const encoded = try httpx.qpack.encodeHeaders(&ctx, &headers, allocator);
defer allocator.free(encoded);

std.debug.print("Encoded {d} headers into {d} bytes\n", .{headers.len, encoded.len});
```

### QPACK Encoder Stream

QPACK uses separate streams for encoder/decoder instructions:

```zig
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);

// Set Dynamic Table Capacity
try httpx.qpack.encodeSetCapacity(4096, &out, allocator);

// Insert With Name Reference (static table, index 17 = :method, value = "POST")
try httpx.qpack.encodeInsertNameRef(true, 17, "POST", &out, allocator);
```

## QUIC Packet Structure

### Connection IDs

```zig
// Create connection IDs
var dcid = httpx.quic.ConnectionId{};
dcid.len = 8;
@memcpy(dcid.data[0..8], &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });

var scid = httpx.quic.ConnectionId{};
scid.len = 4;
@memcpy(scid.data[0..4], &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD });
```

### Long Header (Initial, Handshake, 0-RTT)

```zig
const long_header = httpx.quic.LongHeader{
    .packet_type = .initial,
    .version = .v1,
    .dcid = dcid,
    .scid = scid,
};

var buf: [64]u8 = undefined;
const len = try long_header.encode(&buf);
std.debug.print("Long header: {d} bytes\n", .{len});

// Decode
const decoded = try httpx.quic.LongHeader.decode(&buf);
std.debug.print("Packet type: {s}\n", .{@tagName(decoded.header.packet_type)});
```

### Short Header (1-RTT)

```zig
const short_header = httpx.quic.ShortHeader{
    .dcid = dcid,
    .spin_bit = 0,
    .key_phase = 0,
};

var buf: [32]u8 = undefined;
const len = try short_header.encode(&buf);
```

### Packet Types

| Type | Long Header | Description |
|------|-------------|-------------|
| Initial | ✅ | Connection establishment |
| 0-RTT | ✅ | Early data |
| Handshake | ✅ | TLS handshake completion |
| Retry | ✅ | Address validation |
| 1-RTT | ❌ (Short) | Application data |

## QUIC Frames

### STREAM Frame

Carries application data:

```zig
const stream_frame = httpx.quic.StreamFrame{
    .stream_id = 4, // Client-initiated bidirectional stream
    .offset = 0,
    .data = "Hello, HTTP/3!",
    .fin = false,
};

var buf: [128]u8 = undefined;
const len = try stream_frame.encode(&buf);

// Decode
const decoded = try httpx.quic.StreamFrame.decode(buf[0..len]);
std.debug.print("Data: {s}\n", .{decoded.frame.data});
```

### CRYPTO Frame

Carries TLS handshake data:

```zig
const crypto_frame = httpx.quic.CryptoFrame{
    .offset = 0,
    .data = &[_]u8{ 0x01, 0x00, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' },
};

var buf: [64]u8 = undefined;
const len = try crypto_frame.encode(&buf);
```

### ACK Frame

Acknowledges received packets:

```zig
const ack_frame = httpx.quic.AckFrame{
    .largest_acknowledged = 42,
    .ack_delay = 100,
    .first_ack_range = 10,
    .ack_ranges = &.{},
};

var buf: [64]u8 = undefined;
const len = try ack_frame.encode(&buf);
```

### CONNECTION_CLOSE Frame

Terminates a connection:

```zig
const close_frame = httpx.quic.ConnectionCloseFrame{
    .error_code = @intFromEnum(httpx.quic.TransportError.no_error),
    .frame_type = null,
    .reason_phrase = "graceful shutdown",
};

var buf: [64]u8 = undefined;
const len = try close_frame.encode(false, &buf); // false = transport close
```

### Frame Types

| Type | Value | Description |
|------|-------|-------------|
| PADDING | 0x00 | Connection-level padding |
| PING | 0x01 | Connectivity check |
| ACK | 0x02 | Acknowledgment |
| ACK_ECN | 0x03 | ACK with ECN counts |
| RESET_STREAM | 0x04 | Abrupt stream termination |
| STOP_SENDING | 0x05 | Request sender stop |
| CRYPTO | 0x06 | TLS handshake data |
| NEW_TOKEN | 0x07 | Address validation token |
| STREAM | 0x08-0x0f | Application data |
| MAX_DATA | 0x10 | Connection flow control |
| MAX_STREAM_DATA | 0x11 | Stream flow control |
| MAX_STREAMS_BIDI | 0x12 | Bidirectional stream limit |
| MAX_STREAMS_UNI | 0x13 | Unidirectional stream limit |
| DATA_BLOCKED | 0x14 | Connection blocked |
| STREAM_DATA_BLOCKED | 0x15 | Stream blocked |
| STREAMS_BLOCKED_BIDI | 0x16 | Bidi streams blocked |
| STREAMS_BLOCKED_UNI | 0x17 | Uni streams blocked |
| NEW_CONNECTION_ID | 0x18 | New connection ID |
| RETIRE_CONNECTION_ID | 0x19 | Retire connection ID |
| PATH_CHALLENGE | 0x1a | Path validation |
| PATH_RESPONSE | 0x1b | Path validation response |
| CONNECTION_CLOSE | 0x1c | Transport close |
| CONNECTION_CLOSE_APP | 0x1d | Application close |
| HANDSHAKE_DONE | 0x1e | Handshake complete |

## Variable-Length Integers

QUIC uses a variable-length integer encoding:

```zig
// Encoding
var buf: [8]u8 = undefined;
const len = try httpx.quic.encodeVarInt(15293, &buf);
std.debug.print("Encoded in {d} bytes\n", .{len});

// Decoding
const result = try httpx.quic.decodeVarInt(&buf);
std.debug.print("Value: {d}\n", .{result.value});
```

### Varint Ranges

| Bytes | Range |
|-------|-------|
| 1 | 0 - 63 |
| 2 | 64 - 16,383 |
| 4 | 16,384 - 1,073,741,823 |
| 8 | 1,073,741,824 - 4,611,686,018,427,387,903 |

## HTTP/3 Frame Types

| Type | Value | Description |
|------|-------|-------------|
| DATA | 0x00 | Request/response body |
| HEADERS | 0x01 | QPACK-encoded headers |
| CANCEL_PUSH | 0x03 | Cancel server push |
| SETTINGS | 0x04 | Connection settings |
| PUSH_PROMISE | 0x05 | Server push promise |
| GOAWAY | 0x07 | Connection shutdown |
| MAX_PUSH_ID | 0x0d | Maximum push ID |

## HTTP/3 Unidirectional Stream Types

| Type | Value | Description |
|------|-------|-------------|
| Control | 0x00 | Control stream |
| Push | 0x01 | Server push stream |
| QPACK Encoder | 0x02 | QPACK encoder instructions |
| QPACK Decoder | 0x03 | QPACK decoder instructions |

## Transport Parameters

QUIC transport parameters can be encoded:

```zig
const params = httpx.quic.TransportParameters{
    .original_destination_connection_id = null,
    .max_idle_timeout = 30000,
    .max_udp_payload_size = 1350,
    .initial_max_data = 1048576,
    .initial_max_stream_data_bidi_local = 262144,
    .initial_max_stream_data_bidi_remote = 262144,
    .initial_max_stream_data_uni = 262144,
    .initial_max_streams_bidi = 100,
    .initial_max_streams_uni = 100,
};

const encoded = try params.encode(allocator);
defer allocator.free(encoded);
```

## Flow Control

HTTP/3 uses MAX_DATA and MAX_STREAM_DATA frames for flow control. These are defined as frame types (`max_data = 0x10`, `max_stream_data = 0x11`) and are handled internally by the connection. Flow control limits are configured via transport parameters:

```zig
const params = httpx.quic.TransportParameters{
    .initial_max_data = 10 * 1024 * 1024,           // 10MB connection-level
    .initial_max_stream_data_bidi_local = 1024 * 1024,  // 1MB per stream
    .initial_max_stream_data_bidi_remote = 1024 * 1024,
    .initial_max_stream_data_uni = 1024 * 1024,
};
```

## GOAWAY and CONNECTION_CLOSE

Both client and server handle incoming GOAWAY gracefully:

```zig
// Server sends GOAWAY on clean shutdown
const goaway = httpx.quic.ConnectionCloseFrame{
    .error_code = @intFromEnum(httpx.quic.TransportError.no_error),
    .frame_type = null,
    .reason_phrase = "server shutting down",
};

// CONNECTION_CLOSE (transport vs application)
const transport_close = httpx.quic.ConnectionCloseFrame{
    .error_code = @intFromEnum(httpx.quic.TransportError.no_error),
    .frame_type = null,
    .reason_phrase = "graceful shutdown",
};
const len = try transport_close.encode(false, &buf); // false = transport close
```

## Stream Cancellation

Cancel individual streams without tearing down the connection:

```zig
// RESET_STREAM: abruptly terminates a send stream
const reset = httpx.quic.ResetStreamFrame{
    .stream_id = 4,
    .error_code = 0x06, // application error (user-defined)
    .final_size = 1024,
};

// STOP_SENDING: ask the peer to stop sending on a receive stream
const stop = httpx.quic.StopSendingFrame{
    .stream_id = 8,
    .error_code = 0x01, // application error (user-defined)
};
```

## QPACK Decoder Stream

Decoder stream instructions can be decoded:

```zig
// Section Ack
const ack = try httpx.qpack.decodeSectionAck(data);

// Stream Cancel
const cancel = try httpx.qpack.decodeStreamCancel(data);

// Insert Count Increment
const increment = try httpx.qpack.decodeInsertCountIncrement(data);

// Set Capacity
const capacity = try httpx.qpack.decodeSetCapacity(data);
```

## Running the Example

Run the low-level protocol, high-level runtime, and advanced HTTP/3 examples with:

```bash
zig build run-all-http3_example
./zig-out/bin/http3_example

zig build run-all-http3_client_runtime
zig build run-all-http3_server_runtime
zig build run-all-http3_advanced
```

## See Also

- [Protocol API Reference](/api/protocol) - Full API documentation
- [HTTP/2 Guide](/guide/http2) - HPACK and stream management
- [RFC 9114](https://tools.ietf.org/html/rfc9114) - HTTP/3 specification
- [RFC 9204](https://tools.ietf.org/html/rfc9204) - QPACK specification
- [RFC 9000](https://tools.ietf.org/html/rfc9000) - QUIC transport specification
