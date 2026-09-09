# HTTP/2 Advanced Example

Production HTTP/2 behavior: SETTINGS enforcement, GOAWAY/RST_STREAM,
HPACK security, and trailers. See `examples/http2_multiplex.zig`.

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

## Run

```bash
zig build run-http2-multiplex
```

## What to Verify

- Handshake synchronizes SETTINGS both ways.
- Streams multiplex independently without head-of-line blocking.
