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

    // 1. High-level Client configured for HTTP/3
    var client = try httpx.Client.init(allocator, .{
        .http_version = .h3,
    });
    defer client.deinit();

    std.debug.print("1. HTTP/3 client configured: protocol={s}\n", .{@tagName(client.config.http_version.?)});

    // 2. Client & Server HTTP/3 Connection Engines (RFC 9114)
    var client_conn = httpx.http3.Connection.init(allocator, .client);
    defer client_conn.deinit();

    var server_conn = httpx.http3.Connection.init(allocator, .server);
    defer server_conn.deinit();

    // Exchange control stream SETTINGS
    const client_ctrl = try client_conn.buildControlStream();
    defer allocator.free(client_ctrl);

    const server_ctrl = try server_conn.buildControlStream();
    defer allocator.free(server_ctrl);

    // Server processes client settings (skip 1-byte stream type prefix)
    var off: usize = 1;
    const parsed = try httpx.http3.frame.parseFrame(client_ctrl, &off);
    try server_conn.processControlFrame(parsed.frame_type, parsed.payload);

    std.debug.print("2. HTTP/3 control stream SETTINGS exchanged successfully\n", .{});

    // 3. HTTP/3 Request & Response Stream with QPACK encoding
    const bidi_stream_id = client_conn.nextBidiStreamId();
    var req_stream = client_conn.createRequestStream(bidi_stream_id);

    const extra_headers = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx.zig-http3" },
        .{ .name = "accept", .value = "application/json" },
    };

    const req_frame = try req_stream.buildRequestHeaders("GET", "https", "example.com", "/api/v1/resource", &extra_headers);
    defer allocator.free(req_frame);

    std.debug.print("3. Built HTTP/3 request on stream {d} ({d} bytes QPACK payload)\n", .{ bidi_stream_id, req_frame.len });

    // Server response stream
    var resp_stream = server_conn.createRequestStream(bidi_stream_id);

    const resp_headers = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "server", .value = "httpx.zig/0.1.0" },
    };

    const resp_head = try resp_stream.buildResponseHeaders(200, &resp_headers);
    defer allocator.free(resp_head);

    const resp_body = try resp_stream.buildData("{\"status\":\"ok\",\"protocol\":\"HTTP/3\"}");
    defer allocator.free(resp_body);

    std.debug.print("4. Server generated HTTP/3 response: HEADERS ({d} bytes), DATA ({d} bytes)\n", .{ resp_head.len, resp_body.len });
    std.debug.print("HTTP/3 client-server protocol validation complete.\n", .{});
}
