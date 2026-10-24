# HTTP/3 Example

HTTP/3 and QUIC protocol helpers (QPACK and frame primitives). See
`examples/http3Client.zig` and `examples/http3Quic.zig`.

```zig
var buf: [8]u8 = undefined;
const n = try httpx.protocols.quic.varint.encode(&buf, 1337);
var off: usize = 0;
const v = try httpx.protocols.quic.varint.decode(&buf, &off);
std.debug.print("h3 varint encoded={d} decoded={d}\n", .{ n, v });
```

## Expected Output

```text
h3 varint encoded=2 decoded=1337
```

Encoded size follows QUIC varint rules for the input value (1337 encodes in 2 bytes); decoded value matches the input.

## Run

```bash
zig build run-http3-client
```

## What to Verify

- Varint round trip produces the original numeric value.
- Encoded size follows QUIC varint rules.
- Control-stream SETTINGS exchange validates.
