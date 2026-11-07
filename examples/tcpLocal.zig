//! Local TCP listener/client round trip over loopback with `httpx.tcp`.
//!
//! Run with:
//!   zig build run-tcp-local

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var addr = httpx.Address.loopback4(0);
    var listener = try httpx.tcp.Listener.bindAddress(io, &addr);
    defer listener.close(io);
    const port = listener.localPort();
    std.debug.print("listening on 127.0.0.1:{d}\n", .{port});
    addr.port = port;

    const Th = struct {
        fn run(lst: *httpx.tcp.Listener, ioIn: std.Io) void {
            var accepted = lst.accept(ioIn) catch return;
            defer accepted.close();
            var inBuf: [64]u8 = undefined;
            const n = accepted.read(&inBuf) catch return;
            if (std.mem.eql(u8, inBuf[0..n], "ping")) {
                accepted.writeAll("pong") catch return;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Th.run, .{ &listener, io });
    defer thread.join();

    var client = try httpx.tcp.connectAddress(io, &addr);
    defer client.close();
    try client.writeAll("ping");
    var outBuf: [64]u8 = undefined;
    const n = try client.read(&outBuf);
    std.debug.print("got: {s}\n", .{outBuf[0..n]});
}
