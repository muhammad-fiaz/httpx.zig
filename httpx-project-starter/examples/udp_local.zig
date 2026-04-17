//! UDP Local Send/Recv Example
//!
//! Demonstrates using `httpx.UdpSocket` to send a datagram to a socket bound
//! on loopback. This is self-contained and does not require internet access.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    std.debug.print("=== UDP Local Send/Recv Example ===\n\n", .{});

    var recv_sock = httpx.UdpSocket.create() catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };
    defer recv_sock.close();

    recv_sock.setReuseAddr(true) catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };

    const listen_addr = try httpx.Address.parseIp("127.0.0.1", 0);
    recv_sock.bind(listen_addr) catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };

    const recv_addr = try recv_sock.getLocalAddress();

    var send_sock = httpx.UdpSocket.create() catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };
    defer send_sock.close();

    const msg = "hello over udp";
    _ = send_sock.sendTo(recv_addr, msg) catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };

    var buf: [256]u8 = undefined;
    const got = recv_sock.recvFrom(&buf) catch |err| {
        std.debug.print("Skipping UDP local demo: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Sent: {s}\n", .{msg});
    std.debug.print("Recv: {s}\n", .{buf[0..got.n]});
    std.debug.print("From: {f}\n", .{got.addr});
}
