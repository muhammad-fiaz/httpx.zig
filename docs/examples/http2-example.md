# HTTP/2 Example

Use HTTP/2 protocol primitives (frame headers and stream utilities).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const hdr = httpx.Http2FrameHeader{
        .length = 12,
        .frame_type = .headers,
        .flags = 0x04,
        .stream_id = 1,
    };

    const bytes = hdr.serialize();
    const decoded = httpx.Http2FrameHeader.parse(bytes);

    std.debug.print("h2 frame type={s} stream={d} len={d}\n", .{
        @tagName(decoded.frame_type),
        decoded.stream_id,
        decoded.length,
    });
}
```

## Run

```bash
zig build run-all-http2_example
```

## What to Verify

- Frame header serialize/parse round trip remains stable.
- Frame metadata matches expected stream and type values.
