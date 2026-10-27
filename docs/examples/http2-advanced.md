# HTTP/2 Advanced Example

Production HTTP/2 behavior: SETTINGS enforcement, GOAWAY/RST_STREAM,
HPACK security, and trailers. See `examples/http2Multiplex.zig`.

```zig
var clientSess = try httpx.http2.Session.init(allocator, .client, .{});
defer clientSess.deinit();
var serverSess = try httpx.http2.Session.init(allocator, .server, .{});
defer serverSess.deinit();

try clientSess.startHandshake();
try serverSess.startHandshake();

// Multiplex independent streams on one connection.
const sid = try clientSess.nextClientStreamId();
try clientSess.sendHeaders(sid, &headers, false);
_ = try clientSess.sendData(sid, body, true);
```

GOAWAY/RST_STREAM/WINDOW_UPDATE flow control, PRIORITY/CONTINUATION
frames, PING, and HPACK `Without Indexing` / `Never Indexed` handling live
in `httpx.http2.frame`, `httpx.http2.stream`, and `httpx.http2.hpack`.

## Expected Output

```text
=== HTTP/2 Advanced Protocol & Multiplexing ===
1. HPACK Encoded 5 headers into 87 bytes (dynamic table entries: 5)
   Decoded 5 headers successfully:
     :method: POST
     :scheme: https
     :path: /api/v2/stream
     content-type: application/json
     x-custom-trace: trace-id-998877
2. Handshake exchanged: Client & Server synchronized SETTINGS
3. Multiplexed streams 1, 3, 5 (outbound: 1234 bytes)
HTTP/2 multiplexing demonstration completed successfully.
```

Compressed sizes, outbound byte counts, and stream IDs vary by run; header names/values reflect the demo headers.

## Run

```bash
zig build run-http2-multiplex
```

## What to Verify

- Handshake synchronizes SETTINGS both ways.
- Streams multiplex independently without head-of-line blocking.
