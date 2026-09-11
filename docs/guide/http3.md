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

- **High-level Client Runtime** - `Client` executes real requests over HTTP/3: `client.get("https://host/", .{ .httpVersion = .http3 })` performs a live QUIC + TLS 1.3 handshake (ALPN `h3`, verified chain) over UDP and returns the response.
- **Protocol-level Server Runtime** - serve H3 over QUIC with `httpx.quic` (Endpoint + Pump + HandshakeDriver) and `httpx.http3` builders; see `examples/http3_client.zig` for a complete loopback server. `httpx.Server` has no UDP front-end yet (TCP only).
- **QPACK Header Compression** - RFC 9204 static-table encode/decode with encoder/decoder stream prefixes.
- **QUIC Transport Framing** - STREAM, CRYPTO, ACK, HANDSHAKE_DONE, RESET_STREAM/STOP_SENDING stubs, version negotiation, and transport parameters.
- **Variable-Length Integers** - QUIC varint encoding/decoding.
- **Connection IDs** - Connection ID generation and peer table.
- **Flow Control** - MAX_DATA and MAX_STREAM_DATA frame handling with connection-level and per-stream flow control windows.
- **GOAWAY and CONNECTION_CLOSE** - Frame codecs present; server-initiated graceful shutdown mid-request is future work.
- **Stream Cancellation** - RESET_STREAM and STOP_SENDING frame codecs.

### Deliberate Current Limits

- One request per QUIC connection (no H3 pooling yet); proxy routes are rejected loudly (`Http3ProxyUnsupported`).
- Full handshakes only: no PSK resumption or HRR over QUIC yet (both exist on the TCP/TLS paths).
- No transport-parameter negotiation (both ends run compiled-in defaults), no Retry/token round trip, no loss recovery or congestion control: reliable paths (loopback/LAN) only.
- Request bodies are not sent yet (GET/HEAD-style exchanges).

## High-level Client Usage

HTTP/3 requires `https://` (QUIC is always TLS). Per-request:

```zig
var response = try client.get("https://127.0.0.1:8443/runtime", .{
    .httpVersion = .http3,
    .tls = .{ .verify = .caBundle, .caPem = ca_pem },
    .timeoutMs = 15_000,
});
defer response.deinit();
// response.version == .http3, response.status is the u16 code.
```

Or as the client default (`.httpVersion = .http3` / `.http3 = true` in `ClientConfig` resolves every request to H3).

A wrong chain fails fast and loudly (`error.TlsCertificateNotVerified`); an ALPN mismatch that is not `h3` fails with `error.AlpnNegotiationFailed`. A quiet peer burns the request deadline, then `error.Timeout`.

## Protocol-level Server Usage

An H3 server is one UDP socket plus the protocol pieces (full example in `examples/http3_client.zig`):

```zig
var ep = try httpx.quic.transport.Endpoint.initPort(allocator, io, conn, 8443);
var pump = httpx.quic.Pump{};
try pump.start(&ep, allocator);
defer pump.stop();
var drv = httpx.quic.HandshakeDriver.initServer(allocator, .{
    .certChainPem = cert_pem,
    .privateKeyPem = key_pem,
});
defer drv.deinit();
conn.tls = .{ .ctx = &drv, .start = ..., .onData = ... };
try httpx.quic.handshake.serveHandshake(&ep, &pump, &drv, 15_000);
// ... read request HEADERS on a bidi stream, route, respond ...
```

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
    .keyPhase = 0,
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
    .streamId = 4, // Client-initiated bidirectional stream
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
    .largestAcknowledged = 42,
    .ackDelay = 100,
    .first_ack_range = 10,
    .ack_ranges = &.{},
};

var buf: [64]u8 = undefined;
const len = try ack_frame.encode(&buf);
```

### CONNECTION_CLOSE Frame

Terminates a connection (`httpx.quic.frames.Frame.connectionClose`):

```zig
const close_frame = httpx.quic.frames.Frame{ .connectionClose = .{
    .errorCode = 0, // NO_ERROR
    .triggering_frame_type = 0,
    .reason = "graceful shutdown",
    .application = false, // false = transport close, true = application close
} };
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
const len = try httpx.quic.varint.encode(&buf, 15293);
std.debug.print("Encoded in {d} bytes\n", .{len});

// Decoding
var offset: usize = 0;
const value = try httpx.quic.varint.decode(&buf, &offset);
std.debug.print("Value: {d}\n", .{value});
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
var list = std.ArrayList(u8).empty;
defer list.deinit(allocator);
try httpx.quic.params.encode(&list, allocator, .{
    .maxIdleTimeoutMs = 30000,
    .maxUdpPayloadSize = 1350,
    .initialMaxData = 1048576,
    .initialMaxStreamDataBidiLocal = 262144,
    .initialMaxStreamDataBidiRemote = 262144,
    .initialMaxStreamDataUni = 262144,
    .initialMaxStreamsBidi = 100,
    .initialMaxStreamsUni = 100,
});
// list.items now holds the wire-encoded parameters.
```

## Flow Control

HTTP/3 uses MAX_DATA and MAX_STREAM_DATA frames for flow control. These are defined as frame types (`maxData = 0x10`, `maxStreamData = 0x11`) and are handled internally by the connection. Flow control limits are configured via transport parameters:

```zig
const params = httpx.quic.params.Params{
    .initialMaxData = 10 * 1024 * 1024,           // 10MB connection-level
    .initialMaxStreamDataBidiLocal = 1024 * 1024,  // 1MB per stream
    .initialMaxStreamDataBidiRemote = 1024 * 1024,
    .initialMaxStreamDataUni = 1024 * 1024,
};
```

## GOAWAY and CONNECTION_CLOSE

Both client and server handle incoming GOAWAY gracefully.
`httpx.quic.frames.Frame` carries both variants as `.connectionClose`:

```zig
// Transport close (CONNECTION_CLOSE, type 0x1C)
const transport_close = httpx.quic.frames.Frame{ .connectionClose = .{
    .errorCode = 0, // NO_ERROR
    .triggering_frame_type = 0,
    .reason = "server shutting down",
    .application = false,
} };

// Application close (type 0x1D)
const app_close = httpx.quic.frames.Frame{ .connectionClose = .{
    .errorCode = 0,
    .triggering_frame_type = 0,
    .reason = "graceful shutdown",
    .application = true,
} };
```

## Stream Cancellation

Cancel individual streams without tearing down the connection:

```zig
// RESET_STREAM: abruptly terminates a send stream
const reset = httpx.quic.ResetStreamFrame{
    .streamId = 4,
    .errorCode = 0x06, // application error (user-defined)
    .finalSize = 1024,
};

// STOP_SENDING: ask the peer to stop sending on a receive stream
const stop = httpx.quic.StopSendingFrame{
    .streamId = 8,
    .errorCode = 0x01, // application error (user-defined)
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

Run the client and QUIC examples with:

```bash
zig build run-http3-client
zig build run-http3-quic
```

## See Also

- [Protocol API Reference](/api/protocol) - Full API documentation
- [HTTP/2 Guide](/guide/http2) - HPACK and stream management
- [RFC 9114](https://tools.ietf.org/html/rfc9114) - HTTP/3 specification
- [RFC 9204](https://tools.ietf.org/html/rfc9204) - QPACK specification
- [RFC 9000](https://tools.ietf.org/html/rfc9000) - QUIC transport specification
