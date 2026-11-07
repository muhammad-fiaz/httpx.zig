# TCP Local

Local TCP listener/client round trip over loopback with `httpx.tcp`.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var addr = httpx.Address.loopback4(0);
    var listener = try httpx.socket.tcp.init(allocator, io, .{ .address = httpx.Address.loopback4(0) });
    defer listener.close(io);
    const port = listener.localPort();
    std.debug.print("listening on 127.0.0.1:{d}\n", .{port});
    addr.port = port;

    const Th = struct {
        fn run(lst: *httpx.socket.tcp.Listener, ioIn: std.Io) void {
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

    var client = try httpx.socket.tcp.connectAddress(io, &addr);
    defer client.close();
    try client.writeAll("ping");
    var outBuf: [64]u8 = undefined;
    const n = try client.read(&outBuf);
    std.debug.print("got: {s}\n", .{outBuf[0..n]});
}
```

## Expected Output

```text
listening on 127.0.0.1:54321
got: pong
```

The ephemeral loopback port varies per run; the `pong` payload is fixed by the exchange. Loopback only, no external prerequisites.

## How to Run

```bash
zig build run-tcp-local
```
