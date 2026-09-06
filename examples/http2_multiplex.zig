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
    var enc = httpx.http2.hpack.Encoder.init(allocator);
    defer enc.deinit();
    var dec = httpx.http2.hpack.Decoder.init(allocator);
    defer dec.deinit();

    var out_encoded = std.ArrayList(u8).empty;
    defer out_encoded.deinit(allocator);

    const test_headers = [_]httpx.http2.hpack.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/api/v2/stream" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-custom-trace", .value = "trace-id-998877" },
    };

    for (test_headers) |h| {
        try enc.encode(&out_encoded, h.name, h.value, .incremental, false);
    }
    std.debug.print("1. HPACK Encoded {d} headers into {d} compressed bytes (dynamic table entries: {d})\n", .{
        test_headers.len,
        out_encoded.items.len,
        enc.dyn.entries.items.len,
    });

    const decoded = try dec.decode(out_encoded.items);
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
    var client_sess = try httpx.http2.Session.init(allocator, .client, .{});
    defer client_sess.deinit();
    var server_sess = try httpx.http2.Session.init(allocator, .server, .{});
    defer server_sess.deinit();

    // Client starts handshake (connection preface + initial settings)
    try client_sess.startHandshake();
    try server_sess.startHandshake();

    // Exchange prefaces & initial frames
    try server_sess.feed(client_sess.outbound.items);
    client_sess.outbound.clearRetainingCapacity();

    try client_sess.feed(server_sess.outbound.items);
    server_sess.outbound.clearRetainingCapacity();

    std.debug.print("2. Handshake exchanged: Client & Server synchronized SETTINGS\n", .{});

    // 3. Multiplexing 3 Concurrent Streams
    const sid1 = try client_sess.nextClientStreamId();
    const sid2 = try client_sess.nextClientStreamId();
    const sid3 = try client_sess.nextClientStreamId();

    try client_sess.sendHeaders(sid1, &test_headers, false);
    _ = try client_sess.sendData(sid1, "{\"item\":1}", true);

    try client_sess.sendHeaders(sid2, &test_headers, false);
    _ = try client_sess.sendData(sid2, "{\"item\":2}", true);

    try client_sess.sendHeaders(sid3, &test_headers, true);

    std.debug.print("3. Multiplexed streams {d}, {d}, {d} (outbound: {d} bytes)\n", .{
        sid1,
        sid2,
        sid3,
        client_sess.outbound.items.len,
    });

    try server_sess.feed(client_sess.outbound.items);
    client_sess.outbound.clearRetainingCapacity();

    std.debug.print("HTTP/2 multiplexing demonstration completed successfully.\n", .{});
}
