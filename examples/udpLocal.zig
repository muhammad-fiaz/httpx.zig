//! Local UDP send/receive round trip over loopback with
//! `httpx.socket.udp.Socket`.
//!
//! Run with:
//!   zig build run-udp-local

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var recvSock = try httpx.socket.udp.init(allocator, io, .{});
    defer recvSock.close();

    var sendSock = try httpx.socket.udp.init(allocator, io, .{});
    defer sendSock.close();

    const recvPort = switch (recvSock.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    var dest = try std.Io.net.IpAddress.parseIp4("127.0.0.1", recvPort);
    try sendSock.sendTo(&dest, "hello over udp");

    var buf: [256]u8 = undefined;
    const got = try recvSock.receive(&buf);
    std.debug.print("Recv: {s}\n", .{got.data});
}
