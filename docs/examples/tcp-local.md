# TCP Local

Local TCP listener/client round trip over loopback with `httpx.tcp`.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var holder = httpx.Address{ .family = .ip4, .port = 0 };
    var addr = try holder.parseIp("127.0.0.1");
    addr.port = 0;
    var listener = try httpx.tcp.Listener.bindAddress(io, &addr);
    defer listener.close(io);
    const port = listener.localPort();

    const ServerCtx = struct {
        listener: *httpx.tcp.Listener,
        io: std.Io,
    };
    const Th = struct {
        fn run(ctx: *ServerCtx) void {
            var accepted = ctx.listener.accept(ctx.io) catch return;
            defer accepted.close();
            var inBuf: [64]u8 = undefined;
            const n = accepted.read(&inBuf) catch return;
            if (std.mem.eql(u8, inBuf[0..n], "ping")) {
                accepted.writeAll("pong") catch return;
            }
        }
    };
    var ctx = ServerCtx{ .listener = &listener, .io = io };
    const thread = try std.Thread.spawn(.{}, Th.run, .{&ctx});
    defer thread.join();

    var client = try httpx.tcp.connectAddress(io, &addr);
    defer client.close();
    try client.writeAll("ping");
    var outBuf: [64]u8 = undefined;
    const n = try client.read(&outBuf);
    std.debug.print("got: {s}\n", .{outBuf[0..n]});
}
```
