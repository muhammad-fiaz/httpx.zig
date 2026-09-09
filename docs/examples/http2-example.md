# HTTP/2 Example

HTTP/2 frame headers and stream multiplexing with `httpx.http2`.
See `examples/http2_client.zig` and `examples/http2_multiplex.zig`.

```zig
var hdrBuf: [httpx.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
const hdr = httpx.http2.frame.FrameHeader.parse(&hdrBuf);
var out: [9]u8 = undefined;
hdr.serialize(&out);

var sess = try httpx.http2.Session.init(allocator, .client, .{});
defer sess.deinit();
try sess.startHandshake();
const sid = try sess.nextClientStreamId();
try sess.sendHeaders(sid, &fields, false);
_ = try sess.sendData(sid, body, true);
```

## Run

```bash
zig build run-http2-multiplex
```

## What to Verify

- Frame header serialize/parse round trip remains stable.
- HPACK headers encode and decode back.
- Multiplexed streams complete independently.
