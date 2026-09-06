# HTTP/3 Example

Use HTTP/3 and QUIC protocol helpers (QPACK and frame primitives).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const v: u64 = 1337;
    var buf: [16]u8 = undefined;

    const encoded = httpx.encodeVarInt(v, &buf);
    const decoded = try httpx.decodeVarInt(encoded);

    std.debug.print("h3 varint encoded={d} decoded={d}\n", .{ encoded.len, decoded.value });
}
```

## Run

```bash
zig build run-all-http3_example
```

## What to Verify

- Varint round trip produces original numeric value.
- Encoded size is consistent with QUIC varint rules.
