# HTTP/3 Advanced Example

QPACK stream instructions, QUIC stream cancellation frames, and transport
parameters. See `examples/http3_quic.zig`.

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
`httpx.quic.params`, and `httpx.http3.connection`.

## Run

```bash
zig build run-http3-quic
```

## What to Verify

- Control-stream SETTINGS exchange validates.
- Request streams build valid HEADERS + DATA.
