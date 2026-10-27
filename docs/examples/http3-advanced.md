# HTTP/3 Advanced Example

QPACK stream instructions, QUIC stream cancellation frames, and transport
parameters. See `examples/http3Quic.zig`.

```zig
var clientConn = httpx.http3.Connection.init(allocator, .client);
defer clientConn.deinit();

const ctrl = try clientConn.buildControlStream();
defer allocator.free(ctrl);

const streamId = clientConn.nextBidiStreamId();
var req = clientConn.createRequestStream(streamId);
const head = try req.buildRequestHeaders("GET", "https", "quic.example.org", "/", &headers);
const data = try req.buildData(body);
```

RESET_STREAM / STOP_SENDING cancellation, GOAWAY, QPACK encoder/decoder
stream prefixes, and transport parameters live in `httpx.quic.frames`,
`httpx.quic.transportParameters`, and `httpx.http3.connection`.

## Expected Output

```text
=== HTTP/3 & QUIC Protocol Engine ===
1. QUIC Varint Encoding:
   Value 25 -> encoded 1 bytes, decoded 25
   Value 15293 -> encoded 2 bytes, decoded 15293
   Value 494878333 -> encoded 4 bytes, decoded 494878333
   Value 1512888099419124471 -> encoded 8 bytes, decoded 1512888099419124471
2. Encoded QUIC STREAM Frame (Stream 4, FIN=true) -> 32 bytes
3. QPACK encoded 5 HTTP/3 headers into 45 bytes
4. HTTP/3 request stream #0 constructed: 67 bytes with QPACK
HTTP/3 & QUIC demonstration completed successfully.
```

Encoded byte counts vary with header values; stream IDs follow QUIC client-initiated bidirectional numbering.

## Run

```bash
zig build run-http3-quic
```

## What to Verify

- Control-stream SETTINGS exchange validates.
- Request streams build valid HEADERS + DATA.
