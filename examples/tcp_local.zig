//! TCP Local Send/Recv Example
//!
//! Demonstrates `httpx.Socket` + `httpx.TcpListener` by exchanging one message
//! over loopback without requiring external network access.

const std = @import("std");
const httpx = @import("httpx");

const ServerCtx = struct {
    listener: *httpx.TcpListener,
};

fn serverThread(ctx: *ServerCtx) void {
    var accepted = ctx.listener.accept() catch return;
    defer accepted.socket.close();

    var in_buf: [64]u8 = undefined;
    const n = accepted.socket.read(&in_buf) catch return;
    if (std.mem.eql(u8, in_buf[0..n], "ping")) {
        accepted.socket.writeAll("pong") catch return;
    }
}

pub fn main() !void {
    std.debug.print("=== TCP Local Send/Recv Example ===\n\n", .{});

    const listen_addr = try httpx.Address.parseIp("127.0.0.1", 0);
    var listener = try httpx.TcpListener.init(listen_addr);
    const addr = try listener.getLocalAddress();

    var ctx = ServerCtx{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer thread.join();
    defer listener.deinit();

    var client = try httpx.Socket.createForAddress(addr);
    defer client.close();

    try client.connect(addr);
    try client.writeAll("ping");

    var out_buf: [64]u8 = undefined;
    const n = try client.read(&out_buf);

    std.debug.print("Sent: ping\n", .{});
    std.debug.print("Recv: {s}\n", .{out_buf[0..n]});
}
