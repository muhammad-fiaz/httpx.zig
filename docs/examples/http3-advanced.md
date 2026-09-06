# HTTP/3 Advanced Example

Demonstrates QPACK stream instructions, QUIC stream cancellation frames, and transport parameters.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // QPACK decoder stream instructions
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try httpx.qpack.encodeSectionAck(42, &buf, allocator);
    const ack = try httpx.qpack.decodeSectionAck(buf.items);
    // ack.result.stream_id == 42

    buf.clearRetainingCapacity();
    try httpx.qpack.encodeStreamCancel(7, &buf, allocator);
    const cancel = try httpx.qpack.decodeStreamCancel(buf.items);
    // cancel.result.stream_id == 7

    // QPACK encoder stream instructions
    buf.clearRetainingCapacity();
    try httpx.qpack.encodeInsertNameRef(true, 17, "POST", &buf, allocator);
    const insert = try httpx.qpack.decodeInsertWithNameRef(buf.items, allocator);
    // insert.result.value == "POST"

    // QUIC RESET_STREAM and STOP_SENDING
    const reset = httpx.quic.ResetStreamFrame{
        .stream_id = 4,
        .error_code = 0x06, // H3_REQUEST_CANCELLED
        .final_size = 1024,
    };
    var reset_buf: [64]u8 = undefined;
    const reset_len = try reset.encode(&reset_buf);
    const decoded = try httpx.quic.ResetStreamFrame.decode(reset_buf[0..reset_len]);

    // QUIC transport parameters
    const params = httpx.quic.TransportParameters{
        .max_idle_timeout = 30000,
        .initial_max_data = 10 * 1024 * 1024,
        .active_connection_id_limit = 4,
    };
    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);
    const decoded_params = try httpx.quic.TransportParameters.decode(encoded);
}
```

## Run

```bash
zig build run-all-http3_advanced
```

## What to Verify

- QPACK instruction encode/decode roundtrips correctly for all instruction types.
- RESET_STREAM and STOP_SENDING frames have correct wire format.
- Transport parameters encode/decode preserves all values.
