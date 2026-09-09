# HTTP/3 Example

HTTP/3 and QUIC protocol helpers (QPACK and frame primitives). See
`examples/http3_client.zig` and `examples/http3_quic.zig`.

```zig
var buf: [8]u8 = undefined;
const n = try httpx.quic.varint.encode(&buf, 1337);
var off: usize = 0;
const v = try httpx.quic.varint.decode(&buf, &off);
std.debug.print("h3 varint encoded={d} decoded={d}\n", .{ n, v });
```

## Run

```bash
zig build run-http3-client
```

## What to Verify

- Varint round trip produces the original numeric value.
- Encoded size follows QUIC varint rules.
- Control-stream SETTINGS exchange validates.
