const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var recv_sock = try httpx.UdpSocket.create();
    defer recv_sock.close();

    try recv_sock.setReuseAddr(true);

    const listen_addr = try httpx.Address.parseIp("127.0.0.1", 0);
    try recv_sock.bind(listen_addr);

    const recv_addr = try recv_sock.getLocalAddress();

    var send_sock = try httpx.UdpSocket.create();
    defer send_sock.close();

    const msg = "hello over udp";
    _ = try send_sock.sendTo(recv_addr, msg);

    var buf: [256]u8 = undefined;
    const got = try recv_sock.recvFrom(&buf);

    std.debug.print("Sent: {s}\n", .{msg});
    std.debug.print("Recv: {s}\n", .{buf[0..got.n]});

    var addr_buf: [64]u8 = undefined;
    var addr_writer = std.Io.Writer.fixed(&addr_buf);
    got.addr.format(&addr_writer) catch {};
    std.debug.print("From: {s}\n", .{addr_writer.buffered()});
}
