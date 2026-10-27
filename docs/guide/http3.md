# HTTP/3 Protocol

httpx.zig provides HTTP/3 framing and QPACK primitives (RFC 9114, RFC 9204), a QUIC transport, and high-level client/server runtime paths.

::: warning Custom Implementation
Zig's standard library does not provide HTTP/3 or QUIC support. **httpx.zig implements these protocols entirely from scratch**, following RFC 9114, RFC 9204, and RFC 9000 specifications, including:
- **QPACK** header compression (RFC 9204) with static/dynamic tables, encoder/decoder stream instructions, and blocked-section retry
- **QUIC** transport frame encoding/decoding (RFC 9000), TLS 1.3 handshake, ACK/loss recovery, NewReno congestion control, flow control, RESET_STREAM/STOP_SENDING, transport parameters, and 0-RTT resumption
- **HTTP/3** frame types, SETTINGS, GOAWAY, CONNECTION_CLOSE handling, trailers, and precise protocol-error mapping
- **Limits:** Retry/token validation, QUIC v1/v2 version negotiation, key updates, and client connection pooling are implemented; HelloRetryRequest handling, connection migration, server push, and datagrams are not. The high-level client reuses pooled HTTP/3 connections sequentially.
:::

## Platform Support

The HTTP/3 runtime has loopback integration coverage on the native test host. Cross-compilation checks establish that selected targets compile; they do not establish runtime support on those systems:

| Target | Evidence |
|--------|----------|
| Windows x86_64 | Runtime loopback tests |
| Other targets | Compile/link status only; runtime behavior not established here |

## Features

- **High-level Client Runtime** - `Client` performs QUIC + TLS 1.3 with ALPN `h3`, certificate verification, QPACK dynamic-table encoding, response trailers, and loss recovery.
- **High-level Server Runtime** - `httpx.Server` can bind a UDP endpoint when `.http3 = true` and a default certificate/key identity are provided. It routes supported H3 requests through server handlers. The handshake requires that default identity; selector-only TLS configuration does not initialize the H3 endpoint.
- **Protocol-level Server Runtime** - serve H3 over QUIC directly with `httpx.protocols.quic` (Endpoint + Pump + HandshakeDriver) and `httpx.protocols.http3` builders; see `examples/http3Client.zig` for a complete loopback server.
- **Handshake Lifecycle** - the server confirms the handshake after verifying the client Finished and sends `HANDSHAKE_DONE`; the client confirms on that frame or on a 1-RTT acknowledgment. Confirmation discards the Handshake keys on both ends and late Handshake packets are ignored (RFC 9001 Sections 4.1.2 and 4.9.2).

### Finding the HTTP/3 port

HTTP/3 shares the HTTP/1.1 port number (RFC 9114 Section 3), so a client normally dials the port it already knows. When port `0` was requested, the TCP listener picks an ephemeral port, and Windows keeps separate reserved dynamic ranges for TCP and UDP: that TCP-chosen number can land in a UDP exclusion the stack refuses to bind. In that case only, the endpoint falls back to an ephemeral UDP port of its own. Read the port the server actually bound rather than assuming:

```zig
const server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .http3 = true,
    .tls = .{ .certificatePem = certPem, .privateKeyPem = keyPem },
});

const udpPort = server.http3.port() orelse return error.Http3Disabled;

// True only when the UDP bind could not reuse the TCP port.
if (server.http3.portFallback) {
    std.debug.print("HTTP/3 fell back to its own port {d}\n", .{udpPort});
}
```

An explicit nonzero `.port` never falls back: if the UDP bind fails (for example, the port is already in use or falls in a reserved range), `Server.init` returns the bind error and releases the TCP listener, because moving HTTP/3 to an unannounced port would break the shared-port contract.

Always prefer `server.http3.port()` over `server.localPort()` when dialling HTTP/3.
- **QPACK Header Compression** - RFC 9204 static and dynamic tables with encoder/decoder stream prefixes, insert-count acknowledgments, and blocked-section retry.
- **QUIC Transport Framing** - STREAM, CRYPTO, ACK, HANDSHAKE_DONE, RESET_STREAM/STOP_SENDING, transport parameters, PTO/loss recovery, and NewReno congestion control.
- **Variable-Length Integers** - QUIC varint encoding/decoding.
- **Connection IDs** - Connection ID generation and peer table.
- **Flow Control** - MAX_DATA and MAX_STREAM_DATA frame handling with connection-level and per-stream flow control windows.
- **GOAWAY and CONNECTION_CLOSE** - Frame codecs present; server-initiated graceful shutdown mid-request is future work.
- **Stream Cancellation** - RESET_STREAM and STOP_SENDING frame codecs.

### Deliberate Current Limits

- The high-level HTTP/3 client pools QUIC connections for sequential reuse but does not multiplex concurrent requests over one connection; proxy routes are rejected loudly (`Http3ProxyUnsupported`).
- 0-RTT resumption works over QUIC, but the QUIC driver does not handle HelloRetryRequest; clients always send an X25519 share.
- Retry/token validation, QUIC v1/v2 version negotiation, and 1-RTT key updates are implemented. Set `.http3Retry = true` in the inline options passed to `httpx.Server.init` to require address validation before the Initial flight; the 3x anti-amplification limit otherwise applies until the client Finished is verified. The high-level client honors Retry automatically and resends the ClientHello under the new Initial keys.
- No connection migration, server push, HTTP/3 datagrams, or extended CONNECT.
- Streaming uploads are supported through a request body source. The one-shot
  API buffers response bodies, so streaming downloads are not provided.

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

Or as the client default (`.httpVersion = .http3` / `.http3 = true` in the `Client.init` options resolves every request to H3).

A wrong chain fails fast and loudly (`error.TlsCertificateNotVerified`); an ALPN mismatch that is not `h3` fails with `error.AlpnNegotiationFailed`. A quiet peer burns the request deadline, then `error.Timeout`.

## Protocol-level Server Usage

An H3 server is one UDP socket plus the protocol pieces (full example in `examples/http3Client.zig`):

```zig
var ep = try httpx.quic.transport.Endpoint.init(allocator, io, conn, .{ .port = 8443 });
var pump = httpx.quic.Pump{};
try pump.start(&ep, allocator);
defer pump.stop();
var drv = httpx.quic.HandshakeDriver.initServer(io, allocator, .{
    .certChainPem = cert_pem,
    .privateKeyPem = key_pem,
});
defer drv.deinit();
conn.tls = .{ .ctx = &drv, .onData = httpx.quic.HandshakeDriver.onData };
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

// Both tables are plain arrays; no lookup helpers are exported.
std.debug.print("QPACK static table: {d} entries\n", .{httpx.http3.qpack.STATIC_TABLE_SIZE}); // 99
std.debug.print("HPACK static table: {d} entries\n", .{httpx.http2.hpack.STATIC_TABLE_SIZE}); // 61

for (httpx.http3.qpack.staticTable, 0..) |entry, index| {
    if (std.mem.eql(u8, entry.name, ":method") and std.mem.eql(u8, entry.value, "GET")) {
        std.debug.print("Found :method=GET at index {d}\n", .{index});
        break;
    }
}
```

### QPACK Encoding

```zig
const qpack = httpx.http3.qpack;

var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var enc = qpack.Encoder.init(allocator);
defer enc.deinit();

const headers = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":path", .value = "/api/v3/resources" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "api.example.com" },
    .{ .name = "accept", .value = "application/json" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
};

var fields: std.ArrayList(u8) = .empty;
defer fields.deinit(allocator);

enc.beginSectionForStream(4); // request stream ID
for (headers) |h| try enc.encodeField(&fields, h.name, h.value);

var encoded: std.ArrayList(u8) = .empty;
defer encoded.deinit(allocator);

// The field-section prefix goes before the encoded fields.
const ric = enc.sectionRic();
try enc.encodePrefix(&encoded, ric, ric);
try encoded.appendSlice(allocator, fields.items);

// On the receiving side:
var dec = qpack.Decoder.init(allocator);
defer dec.deinit();
const decoded = try dec.decodeSectionCounted(encoded.items, 4, null);
defer dec.freeFields(decoded);
std.debug.print("Encoded {d} headers into {d} bytes\n", .{ decoded.len, encoded.items.len });
```

### QPACK Encoder Stream

QPACK uses separate streams for encoder/decoder instructions:

```zig
var enc = httpx.http3.qpack.Encoder.init(allocator);
defer enc.deinit();

// Queues a Set Dynamic Table Capacity instruction.
enc.setMaxTableCapacity(4096);

// Encoding a field with the dynamic table active queues an Insert
// instruction for a name/value pair the table does not already hold.
var fields: std.ArrayList(u8) = .empty;
defer fields.deinit(allocator);
try enc.encodeField(&fields, "x-example", "value");

// Send these bytes on the QPACK encoder unidirectional stream.
const encoder_bytes = try enc.takeEncoderBytes();
defer allocator.free(encoder_bytes);

// Peer side: feed them to the Decoder before decoding field sections.
var dec = httpx.http3.qpack.Decoder.init(allocator);
defer dec.deinit();
dec.setMaxTableCapacity(4096);
try dec.readEncoderStream(encoder_bytes, true);
```

## QUIC Packet Structure

### Connection IDs

```zig
// Connection IDs are 0..20 byte slices; there is no ConnectionId wrapper.
const dcid = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
const scid = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

// httpx.quic.connectionId.Registry tracks peer-issued CIDs,
// retirePriorTo, rotation, and RETIRE_CONNECTION_ID generation.
```

### Long Header (Initial, Handshake, 0-RTT)

```zig
const packet = httpx.quic.packet;

var buf: [64]u8 = undefined;
const len = try packet.writeLongHeader(&buf, .{
    .type = .initial,
    .version = @intFromEnum(packet.Version.version1),
    .dcid = &dcid,
    .scid = &scid,
    .pnLen = 1,
    .protectedPayloadLen = 64,
});

// Parse an UNPROTECTED header.
const decoded = try packet.parseLongHeader(buf[0..len]);
std.debug.print("Packet type: {s}\n", .{@tagName(decoded.header.type)});
```

### Short Header (1-RTT)

```zig
var buf: [32]u8 = undefined;
const len = try packet.writeShortHeader(&buf, .{ .dcid = &dcid, .pnLen = 1 });

buf[len] = 0; // placeholder packet-number byte
const decoded = try packet.parseShortHeader(buf[0 .. len + 1], dcid.len);
std.debug.print("Key phase: {}\n", .{decoded.keyPhase});
```

### Packet Types

| Type | Long Header | Description |
|------|-------------|-------------|
| Initial | ✅ | Connection establishment |
| 0-RTT | ✅ | Early data |
| Handshake | ✅ | TLS handshake completion |
| Retry | ✅ | Address validation |
| 1-RTT | âŒ (Short) | Application data |

## QUIC Frames

### STREAM Frame

Carries application data:

```zig
const frames = httpx.quic.frames;

var encoded = try httpx.quic.encodeFrame(allocator, .{ .stream = .{
    .id = 4, // client-initiated bidirectional stream
    .offset = 0,
    .data = "Hello, HTTP/3!",
    .fin = false,
} });
defer encoded.deinit(allocator);

var pos: usize = 0;
const decoded = try frames.decode(encoded.items, &pos);
switch (decoded) {
    .stream => |s| std.debug.print("Data: {s}\n", .{s.data}),
    else => unreachable,
}
```

### CRYPTO Frame

Carries TLS handshake data:

```zig
var encoded = try httpx.quic.encodeFrame(allocator, .{ .crypto = .{
    .offset = 0,
    .data = &[_]u8{ 0x01, 0x00, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' },
} });
defer encoded.deinit(allocator);
```

### ACK Frame

Acknowledges received packets:

ACK frames are built from acknowledged ranges rather than a single flat
struct:

```zig
const blocks = [_]httpx.quic.frames.AckBlock{
    .{ .highest = 42, .len = 11 }, // acknowledges packets 32..42
};

var out: std.ArrayList(u8) = .empty;
defer out.deinit(allocator);
try httpx.quic.frames.encodeAckFromBlocks(
    &out,
    allocator,
    42,
    100, // ACK delay
    &blocks,
    null, // optional ECN counts
);
```

### CONNECTION_CLOSE Frame

Terminates a connection (`httpx.quic.frames.Frame.connectionClose`):

```zig
const close_frame = httpx.quic.frames.Frame{ .connectionClose = .{
    .errorCode = 0, // NO_ERROR
    .triggeringFrameType = 0,
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
try httpx.quic.transportParameters.encode(&list, allocator, .{
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
const params = httpx.quic.transportParameters.Params{
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
    .triggeringFrameType = 0,
    .reason = "server shutting down",
    .application = false,
} };

// Application close (type 0x1D)
const app_close = httpx.quic.frames.Frame{ .connectionClose = .{
    .errorCode = 0,
    .triggeringFrameType = 0,
    .reason = "graceful shutdown",
    .application = true,
} };
```

## Stream Cancellation

Cancel individual streams without tearing down the connection:

```zig
// RESET_STREAM: abruptly terminates a send stream
var reset = try httpx.quic.encodeFrame(allocator, .{ .resetStream = .{
    .streamId = 4,
    .errorCode = 0x06, // application error (user-defined)
    .finalSize = 1024,
} });
defer reset.deinit(allocator);

// STOP_SENDING: ask the peer to stop sending on a receive stream
var stop = try httpx.quic.encodeFrame(allocator, .{ .stopSending = .{
    .streamId = 8,
    .errorCode = 0x01, // application error (user-defined)
} });
defer stop.deinit(allocator);
```

## QPACK Decoder Stream

Decoder-stream instructions (Section Acknowledgment, Stream Cancellation,
Insert Count Increment) are parsed by the encoder rather than by public
standalone decoders. Feed decoder-stream bytes as they arrive:

```zig
var enc = httpx.http3.qpack.Encoder.init(allocator);
defer enc.deinit();

// Pass fin = true when these are the stream's final bytes.
try enc.readDecoderStream(data, true);
```

The decoder emits a Section Acknowledgment into `ackOut` when dynamic
entries are used:

```zig
var ack_bytes: std.ArrayList(u8) = .empty;
defer ack_bytes.deinit(allocator);

const fields = try dec.decodeSectionCounted(section, streamId, &ack_bytes);
defer dec.freeFields(fields);
// Send ack_bytes on the QPACK decoder unidirectional stream.
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
