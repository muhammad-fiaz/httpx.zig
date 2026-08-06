//! WebSocket Server Example
//!
//! Demonstrates WebSocket handshake detection, key extraction, accept key
//! computation, frame encoding/decoding, and bidirectional messaging.
//! Uses the flat WebSocket API: isWebSocketUpgrade, wsExtractKey,
//! wsAcceptKey, wsEncodeFrame, wsDecodeFrame.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== WebSocket Server Example ===\n\n", .{});

    // 1. Simulate WebSocket handshake
    std.debug.print("--- WebSocket Handshake ---\n", .{});

    var upgrade_req = try httpx.Request.init(allocator, .GET, "ws://localhost:8080/ws");
    defer upgrade_req.deinit();
    try upgrade_req.headers.set("Upgrade", "websocket");
    try upgrade_req.headers.set("Connection", "Upgrade");
    try upgrade_req.headers.set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try upgrade_req.headers.set("Sec-WebSocket-Version", "13");

    const is_upgrade = httpx.isWebSocketUpgrade(&upgrade_req);
    std.debug.print("Is WebSocket upgrade: {}\n", .{is_upgrade});

    const key = httpx.wsExtractKey(&upgrade_req);
    std.debug.print("Sec-WebSocket-Key: {s}\n", .{key.?});

    const accept_key = try httpx.wsAcceptKey(key.?, allocator);
    defer allocator.free(accept_key);
    std.debug.print("Sec-WebSocket-Accept: {s}\n", .{accept_key});

    // 2. Send messages (text and binary frames)
    std.debug.print("\n--- Sending Messages ---\n", .{});

    const text_frame = try httpx.wsTextFrame(allocator, "Hello from server!");
    defer allocator.free(text_frame);
    var decoded = try httpx.wsDecodeFrame(allocator, text_frame);
    defer decoded.frame.deinit();
    std.debug.print("Text frame: \"{s}\"\n", .{decoded.frame.payload});

    const bin_data: []const u8 = &.{ 0xCA, 0xFE, 0xBA, 0xBE };
    const bin_frame = try httpx.wsBinaryFrame(allocator, bin_data);
    defer allocator.free(bin_frame);
    var bin_decoded = try httpx.wsDecodeFrame(allocator, bin_frame);
    defer bin_decoded.frame.deinit();
    std.debug.print("Binary frame: {d} bytes\n", .{bin_decoded.frame.payload.len});

    // 3. Masked frame (client -> server)
    std.debug.print("\n--- Masked Frame (Client -> Server) ---\n", .{});
    const mask_key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    const masked = try httpx.wsEncodeFrame(allocator, .text, "masked payload", true, true, mask_key);
    defer allocator.free(masked);
    var masked_dec = try httpx.wsDecodeFrame(allocator, masked);
    defer masked_dec.frame.deinit();
    std.debug.print("Masked payload: \"{s}\"\n", .{masked_dec.frame.payload});

    // 4. Control frames
    std.debug.print("\n--- Control Frames ---\n", .{});
    const ping = try httpx.wsPingFrame(allocator, "ping");
    defer allocator.free(ping);
    const pong = try httpx.wsPongFrame(allocator, "pong");
    defer allocator.free(pong);
    const close = try httpx.wsCloseFrame(allocator, .normal, "goodbye");
    defer allocator.free(close);

    var ping_dec = try httpx.wsDecodeFrame(allocator, ping);
    defer ping_dec.frame.deinit();
    var pong_dec = try httpx.wsDecodeFrame(allocator, pong);
    defer pong_dec.frame.deinit();
    var close_dec = try httpx.wsDecodeFrame(allocator, close);
    defer close_dec.frame.deinit();

    std.debug.print("PING: {s}\n", .{ping_dec.frame.payload});
    std.debug.print("PONG: {s}\n", .{pong_dec.frame.payload});
    std.debug.print("CLOSE: {s}\n", .{close_dec.frame.payload});

    // 5. Large payload (extended length)
    std.debug.print("\n--- Extended Payload ---\n", .{});
    const big = try allocator.alloc(u8, 300);
    defer allocator.free(big);
    @memset(big, 0xAB);
    const big_frame = try httpx.wsBinaryFrame(allocator, big);
    defer allocator.free(big_frame);
    var big_dec = try httpx.wsDecodeFrame(allocator, big_frame);
    defer big_dec.frame.deinit();
    std.debug.print("Payload: {d} bytes, roundtrip: {}\n", .{ big.len, std.mem.eql(u8, big_dec.frame.payload, big) });

    std.debug.print("\n=== WebSocket Server Example Complete ===\n", .{});
}
