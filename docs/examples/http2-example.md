# HTTP/2 Example

HTTP/2 frame headers and stream multiplexing with `httpx.protocols.http2`.
See `examples/http2Client.zig` and `examples/http2Multiplex.zig`.

```zig
var hdrBuf: [httpx.protocols.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
const hdr = httpx.protocols.http2.FrameHeader.parse(&hdrBuf);
var out: [9]u8 = undefined;
hdr.serialize(&out);

var sess = try httpx.protocols.http2.Session.init(allocator, .client, .{});
defer sess.deinit();
try sess.startHandshake();
const sid = try sess.nextClientStreamId();
try sess.sendHeaders(sid, &fields, false);
_ = try sess.sendData(sid, body, true);
```

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

Compressed sizes, outbound bytes, and stream IDs vary; headers reflect the demo set.

## Run

```bash
zig build run-http2-multiplex
```

## What to Verify

- Frame header serialize/parse round trip remains stable.
- HPACK headers encode and decode back.
- Multiplexed streams complete independently.
