# Example: Http3 Quic

Demonstrates http3Quic.zig using the canonical HTTPX API.

## Complete Example

```zig
//! HTTP/3 & QUIC Transport Engine Example.
//!
//! Demonstrates:
//! 1. QUIC Packet construction, Variable-length integer encoding (RFC 9000)
//! 2. QUIC Frame serialization (STREAM, ACK, CRYPTO, CONNECTION_CLOSE)
//! 3. QPACK dynamic table encoder/decoder operations (RFC 9204)
//! 4. Full HTTP/3 control & request stream multiplexing (RFC 9114)
//! Run with: `zig build run-http3-quic`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTP/3 & QUIC Protocol Engine ===\n", .{});

    // 1. QUIC Variable-Length Integer Encoding (RFC 9000 Section 16)
    var varintBuf: [16]u8 = undefined;
    const testValues = [_]u62{ 25, 15293, 494878333, 1512888099419124471 };
    std.debug.print("1. QUIC Varint Encoding:\n", .{});
    for (testValues) |val| {
        const n = try httpx.protocols.quic.varint.encode(&varintBuf, val);
        var off: usize = 0;
        const decodedVal = try httpx.protocols.quic.varint.decode(varintBuf[0..n], &off);
        std.debug.print("   Value {d} -> encoded {d} bytes, decoded {d}\n", .{ val, n, decodedVal });
    }

    // 2. QUIC Frame Construction (RFC 9000 section 12.4) - using clean wrapper
    var frame = try httpx.protocols.quic.encodeFrame(allocator, .{
        .stream = .{
            .id = 4,
            .offset = 0,
            .data = "HTTP/3 over QUIC binary stream",
            .fin = true,
        },
    });
    defer frame.deinit(allocator);
    std.debug.print("2. Encoded QUIC STREAM Frame (Stream 4, FIN=true) -> {d} bytes\n", .{frame.items.len});

    // 3. QPACK Dynamic Table Encoding (RFC 9204)
    var qenc = httpx.protocols.http3.qpack.Encoder.init(allocator);
    defer qenc.deinit();
    var qdec = httpx.protocols.http3.qpack.Decoder.init(allocator);
    defer qdec.deinit();

    var fieldSection = std.ArrayList(u8).empty;
    defer fieldSection.deinit(allocator);

    // Required Insert Count & Delta Base prefix
    try fieldSection.appendSlice(allocator, "\x00\x00");
    try qenc.encodeField(&fieldSection, ":method", "GET");
    try qenc.encodeField(&fieldSection, ":path", "/index.html");
    try qenc.encodeField(&fieldSection, ":scheme", "https");
    try qenc.encodeField(&fieldSection, ":authority", "quic.example.org");
    try qenc.encodeField(&fieldSection, "x-quic-version", "v1");

    std.debug.print("3. QPACK encoded 5 HTTP/3 headers into {d} bytes\n", .{fieldSection.items.len});

    // 4. HTTP/3 Client-Server Connection Lifecycle
    var clientConn = httpx.protocols.http3.Connection.init(allocator, .client);
    defer clientConn.deinit();
    var serverConn = httpx.protocols.http3.Connection.init(allocator, .server);
    defer serverConn.deinit();

    const clientCtrl = try clientConn.buildControlStream();
    defer allocator.free(clientCtrl);

    var off: usize = 1;
    const parsedFrame = try httpx.protocols.http3.frame.parseFrame(clientCtrl, &off);
    try serverConn.processControlFrame(parsedFrame.frameType, parsedFrame.payload);

    const bidiId = clientConn.nextBidiStreamId();
    var reqStream = clientConn.createRequestStream(bidiId);

    const reqHeaders = [_]httpx.protocols.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx-quic-client" },
    };
    const reqBytes = try reqStream.buildRequestHeaders("GET", "https", "quic.example.org", "/", &reqHeaders);
    defer allocator.free(reqBytes);

    std.debug.print("4. HTTP/3 request stream #{d} constructed: {d} bytes with QPACK\n", .{ bidiId, reqBytes.len });
    std.debug.print("HTTP/3 & QUIC demonstration completed successfully.\n", .{});
}
```

## Expected Output

```text
=== HTTP/3 & QUIC Protocol Engine ===
1. QUIC Varint Encoding:
   Value 25 -> encoded 1 bytes, decoded 25
   Value 15293 -> encoded 2 bytes, decoded 15293
   Value 494878333 -> encoded 4 bytes, decoded 494878333
   Value 1512888099419124471 -> encoded 8 bytes, decoded 1512888099419124471
2. Encoded QUIC STREAM Frame (Stream 4, FIN=true) -> 32 bytes
3. QPACK encoded 5 HTTP/3 headers into 45 bytes
4. HTTP/3 request stream #0 constructed: 67 bytes with QPACK
HTTP/3 & QUIC demonstration completed successfully.
```

Encoded byte counts vary with header values; stream IDs follow QUIC client-initiated numbering.

## How to Run

```bash
zig build run-http3-quic
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
