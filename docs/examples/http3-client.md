# Example: Http3 Client

Demonstrates http3Client.zig using the canonical HTTPX API.

## Complete Example

```zig
//! HTTP/3 protocol example.
//!
//! Demonstrates HTTP/3 (RFC 9114) and QPACK (RFC 9204) request and response
//! building, SETTINGS frame exchanges, and high-level client initialization.
//! Run with: `zig build run-http3-client`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. High-level Client configured for HTTP/3
    var client = httpx.Client.init(allocator, io, .{
        .httpVersion = .http3,
    });
    defer client.deinit();

    std.debug.print("1. HTTP/3 client configured: protocol={s}\n", .{@tagName(client.config.httpVersion.?)});

    // 2. Client & Server HTTP/3 Connection Engines (RFC 9114)
    var clientConn = httpx.protocols.http3.Connection.init(allocator, .client);
    defer clientConn.deinit();

    var serverConn = httpx.protocols.http3.Connection.init(allocator, .server);
    defer serverConn.deinit();

    // Exchange control stream SETTINGS
    const clientCtrl = try clientConn.buildControlStream();
    defer allocator.free(clientCtrl);

    const serverCtrl = try serverConn.buildControlStream();
    defer allocator.free(serverCtrl);

    // Server processes client settings (skip 1-byte stream type prefix)
    var off: usize = 1;
    const parsed = try httpx.protocols.http3.frame.parseFrame(clientCtrl, &off);
    try serverConn.processControlFrame(parsed.frameType, parsed.payload);

    std.debug.print("2. HTTP/3 control stream SETTINGS exchanged successfully\n", .{});

    // 3. HTTP/3 Request & Response Stream with QPACK encoding
    const bidiStreamId = clientConn.nextBidiStreamId();
    var reqStream = clientConn.createRequestStream(bidiStreamId);

    const extraHeaders = [_]httpx.protocols.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx.zig-http3" },
        .{ .name = "accept", .value = "application/json" },
    };

    const reqFrame = try reqStream.buildRequestHeaders("GET", "https", "example.com", "/api/v1/resource", &extraHeaders);
    defer allocator.free(reqFrame);

    std.debug.print("3. Built HTTP/3 request on stream {d} ({d} bytes QPACK payload)\n", .{ bidiStreamId, reqFrame.len });

    // Server response stream
    var respStream = serverConn.createRequestStream(bidiStreamId);

    const respHeaders = [_]httpx.protocols.http3.qpack.FieldLine{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "server", .value = "httpx.zig/0.1.0" },
    };

    const respHead = try respStream.buildResponseHeaders(200, &respHeaders);
    defer allocator.free(respHead);

    const respBody = try respStream.buildData("{\"status\":\"ok\",\"protocol\":\"HTTP/3\"}");
    defer allocator.free(respBody);

    std.debug.print("4. Server generated HTTP/3 response: HEADERS ({d} bytes), DATA ({d} bytes)\n", .{ respHead.len, respBody.len });
    std.debug.print("HTTP/3 client-server protocol validation complete.\n", .{});

    try liveLoopbackDemo(allocator, io);
}
```

## Expected Output

```text
1. HTTP/3 client configured: protocol=http3
2. HTTP/3 control stream SETTINGS exchanged successfully
3. Built HTTP/3 request on stream 0 (67 bytes QPACK payload)
4. Server generated HTTP/3 response: HEADERS (32 bytes), DATA (45 bytes)
HTTP/3 client-server protocol validation complete.
=== HTTP/3 live loopback (QUIC + TLS 1.3 over UDP) ===
5. LIVE client.get: status=200 version=http3 body={"path":"/api/v1/resource","protocol":"HTTP/3"}
H3 LIVE DEMO VERIFICATION PASSED
```

Stream IDs, QPACK byte counts, and ports vary per run; status is 200 on success. See `examples/http3Client.zig` for the full `liveLoopbackDemo` helper.

## How to Run

```bash
zig build run-http3-client
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
