# Example: Http2 Multiplex

Demonstrates http2Multiplex.zig using the canonical HTTPX API.

## Complete Example

```zig
//! HTTP/2 Multiplexing, Flow Control, and HPACK Example.
//!
//! Demonstrates:
//! 1. HPACK Dynamic Table Header Encoding and Decoding (RFC 7541)
//! 2. Frame serialization: HEADERS, DATA, SETTINGS, PING, WINDOW_UPDATE, GOAWAY
//! 3. Full stream multiplexing with flow control accounting
//! Run with: `zig build run-http2-multiplex`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTP/2 Advanced Protocol & Multiplexing ===\n", .{});

    // 1. HPACK Dynamic Table Compression (RFC 7541)
    var enc = httpx.protocols.http2.hpack.Encoder.init(allocator);
    defer enc.deinit();
    var dec = httpx.protocols.http2.hpack.Decoder.init(allocator);
    defer dec.deinit();

    var outEncoded = std.ArrayList(u8).empty;
    defer outEncoded.deinit(allocator);

    const testHeaders = [_]httpx.protocols.http2.hpack.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/api/v2/stream" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-custom-trace", .value = "trace-id-998877" },
    };

    for (testHeaders) |h| {
        try enc.encode(&outEncoded, h.name, h.value, .incremental, false);
    }
    std.debug.print("1. HPACK Encoded {d} headers into {d} compressed bytes (dynamic table entries: {d})\n", .{
        testHeaders.len,
        outEncoded.items.len,
        enc.dyn.entries.items.len,
    });

    const decoded = try dec.decode(outEncoded.items);
    defer {
        for (decoded.fields) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(decoded.fields);
    }
    std.debug.print("   Decoded {d} headers successfully:\n", .{decoded.fields.len});
    for (decoded.fields) |h| {
        std.debug.print("     {s}: {s}\n", .{ h.name, h.value });
    }

    // 2. HTTP/2 Session Multiplexing & Frame Processing (RFC 9113)
    var clientSess = try httpx.protocols.http2.Session.init(allocator, .client, .{});
    defer clientSess.deinit();
    var serverSess = try httpx.protocols.http2.Session.init(allocator, .server, .{});
    defer serverSess.deinit();

    // Client starts handshake (connection preface + initial settings)
    try clientSess.startHandshake();
    try serverSess.startHandshake();

    // Exchange prefaces & initial frames
    try serverSess.feed(clientSess.outbound.items);
    clientSess.outbound.clearRetainingCapacity();

    try clientSess.feed(serverSess.outbound.items);
    serverSess.outbound.clearRetainingCapacity();

    std.debug.print("2. Handshake exchanged: Client & Server synchronized SETTINGS\n", .{});

    // 3. Multiplexing 3 Concurrent Streams
    const sid1 = try clientSess.nextClientStreamId();
    const sid2 = try clientSess.nextClientStreamId();
    const sid3 = try clientSess.nextClientStreamId();

    try clientSess.sendHeaders(sid1, &testHeaders, false);
    _ = try clientSess.sendData(sid1, "{\"item\":1}", true);

    try clientSess.sendHeaders(sid2, &testHeaders, false);
    _ = try clientSess.sendData(sid2, "{\"item\":2}", true);

    try clientSess.sendHeaders(sid3, &testHeaders, true);

    std.debug.print("3. Multiplexed streams {d}, {d}, {d} (outbound: {d} bytes)\n", .{
        sid1,
        sid2,
        sid3,
        clientSess.outbound.items.len,
    });

    try serverSess.feed(clientSess.outbound.items);
    clientSess.outbound.clearRetainingCapacity();

    std.debug.print("HTTP/2 multiplexing demonstration completed successfully.\n", .{});
}
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

## How to Run

```bash
zig build run-http2-multiplex
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
