const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try httpx.wsAcceptKey(client_key, allocator);
    defer allocator.free(accept);
    std.debug.print("Client key:   {s}\n", .{client_key});
    std.debug.print("Accept key:   {s}\n", .{accept});
    std.debug.print("RFC expected: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\n", .{});
    std.debug.print("Match: {}\n\n", .{std.mem.eql(u8, accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")});

    var req = try httpx.Request.init(allocator, .GET, "ws://localhost:8080/chat");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try req.headers.set("Sec-WebSocket-Key", client_key);
    try req.headers.set("Sec-WebSocket-Version", "13");

    std.debug.print("isWebSocketUpgrade: {}\n", .{httpx.isWebSocketUpgrade(&req)});
    std.debug.print("wsExtractKey:       {s}\n\n", .{httpx.wsExtractKey(&req).?});

    const tf = try httpx.wsTextFrame(allocator, "Hello, WebSocket!");
    defer allocator.free(tf);
    var tr = try httpx.wsDecodeFrame(allocator, tf);
    defer tr.frame.deinit();
    std.debug.print("opcode:  {s}\n", .{@tagName(tr.frame.opcode)});
    std.debug.print("fin:     {}\n", .{tr.frame.fin});
    std.debug.print("payload: \"{s}\"\n", .{tr.frame.payload});
    std.debug.print("match:   {}\n\n", .{std.mem.eql(u8, tr.frame.payload, "Hello, WebSocket!")});

    const bin_data: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF };
    const mask_key: [4]u8 = .{ 0x37, 0xfa, 0x21, 0x3d };
    const bf = try httpx.wsEncodeFrame(allocator, .binary, bin_data, true, true, mask_key);
    defer allocator.free(bf);
    var br = try httpx.wsDecodeFrame(allocator, bf);
    defer br.frame.deinit();
    std.debug.print("opcode:      {s}\n", .{@tagName(br.frame.opcode)});
    std.debug.print("masked input:  true\n", .{});
    std.debug.print("decoded bytes: {d}\n", .{br.frame.payload.len});
    std.debug.print("roundtrip:   {}\n\n", .{std.mem.eql(u8, br.frame.payload, bin_data)});

    const ping = try httpx.wsPingFrame(allocator, "alive");
    defer allocator.free(ping);
    const pong = try httpx.wsPongFrame(allocator, "alive");
    defer allocator.free(pong);
    const close = try httpx.wsCloseFrame(allocator, .normal, "bye");
    defer allocator.free(close);

    var ping_r = try httpx.wsDecodeFrame(allocator, ping);
    defer ping_r.frame.deinit();
    var pong_r = try httpx.wsDecodeFrame(allocator, pong);
    defer pong_r.frame.deinit();
    var close_r = try httpx.wsDecodeFrame(allocator, close);
    defer close_r.frame.deinit();

    std.debug.print("PING  opcode: {s}  isControl: {}\n", .{ @tagName(ping_r.frame.opcode), ping_r.frame.opcode.isControl() });
    std.debug.print("PONG  opcode: {s}  isControl: {}\n", .{ @tagName(pong_r.frame.opcode), pong_r.frame.opcode.isControl() });
    std.debug.print("CLOSE opcode: {s}  isControl: {}\n\n", .{ @tagName(close_r.frame.opcode), close_r.frame.opcode.isControl() });

    const big = try allocator.alloc(u8, 200);
    defer allocator.free(big);
    @memset(big, 0xAB);
    const big_frame = try httpx.wsBinaryFrame(allocator, big);
    defer allocator.free(big_frame);
    var big_r = try httpx.wsDecodeFrame(allocator, big_frame);
    defer big_r.frame.deinit();
    std.debug.print("payload: {d} bytes (uses 2-byte extended length)\n", .{big.len});
    std.debug.print("encoded: {d} bytes  roundtrip: {}\n\n", .{ big_frame.len, std.mem.eql(u8, big_r.frame.payload, big) });

    const opcodes = [_]httpx.WsOpcode{ .text, .binary, .continuation, .ping, .pong, .close };
    for (opcodes) |op| {
        std.debug.print("  {s: <12}  isData={}  isControl={}\n", .{
            @tagName(op), op.isData(), op.isControl(),
        });
    }

    std.debug.print("\n", .{});
    const codes = [_]httpx.WsCloseCode{ .normal, .going_away, .protocol_error, .message_too_big, .internal_error };
    for (codes) |c| {
        std.debug.print("  {s} = {d}\n", .{ @tagName(c), @intFromEnum(c) });
    }
}
