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
    var varint_buf: [16]u8 = undefined;
    const test_values = [_]u62{ 25, 15293, 494878333, 1512888099419124471 };
    std.debug.print("1. QUIC Varint Encoding:\n", .{});
    for (test_values) |val| {
        const n = try httpx.quic.varint.encode(&varint_buf, val);
        var off: usize = 0;
        const decoded_val = try httpx.quic.varint.decode(varint_buf[0..n], &off);
        std.debug.print("   Value {d} -> encoded {d} bytes, decoded {d}\n", .{ val, n, decoded_val });
    }

    // 2. QUIC Frame Construction (RFC 9000 section 12.4) - using clean wrapper
    var frame = try httpx.quic.encodeFrame(allocator, .{
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
    var qenc = httpx.http3.qpack.Encoder.init(allocator);
    defer qenc.deinit();
    var qdec = httpx.http3.qpack.Decoder.init(allocator);
    defer qdec.deinit();

    var field_section = std.ArrayList(u8).empty;
    defer field_section.deinit(allocator);

    // Required Insert Count & Delta Base prefix
    try field_section.appendSlice(allocator, "\x00\x00");
    try qenc.encodeField(&field_section, ":method", "GET");
    try qenc.encodeField(&field_section, ":path", "/index.html");
    try qenc.encodeField(&field_section, ":scheme", "https");
    try qenc.encodeField(&field_section, ":authority", "quic.example.org");
    try qenc.encodeField(&field_section, "x-quic-version", "v1");

    std.debug.print("3. QPACK encoded 5 HTTP/3 headers into {d} bytes\n", .{field_section.items.len});

    // 4. HTTP/3 Client-Server Connection Lifecycle
    var client_conn = httpx.http3.Connection.init(allocator, .client);
    defer client_conn.deinit();
    var server_conn = httpx.http3.Connection.init(allocator, .server);
    defer server_conn.deinit();

    const client_ctrl = try client_conn.buildControlStream();
    defer allocator.free(client_ctrl);

    var off: usize = 1;
    const parsed_frame = try httpx.http3.frame.parseFrame(client_ctrl, &off);
    try server_conn.processControlFrame(parsed_frame.frame_type, parsed_frame.payload);

    const bidi_id = client_conn.nextBidiStreamId();
    var req_stream = client_conn.createRequestStream(bidi_id);

    const req_headers = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx-quic-client" },
    };
    const req_bytes = try req_stream.buildRequestHeaders("GET", "https", "quic.example.org", "/", &req_headers);
    defer allocator.free(req_bytes);

    std.debug.print("4. HTTP/3 request stream #{d} constructed: {d} bytes with QPACK\n", .{ bidi_id, req_bytes.len });
    std.debug.print("HTTP/3 & QUIC demonstration completed successfully.\n", .{});
}
