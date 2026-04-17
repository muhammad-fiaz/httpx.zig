# TCP Local

Run a local TCP listener/client round trip over loopback.

This demo uses the stream-style socket aliases `read(...)` and `writeAll(...)` (equivalent to `recv(...)` and `sendAll(...)`).

## Demo Program

```zig
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
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();

    var ctx = ServerCtx{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer thread.join();

    var client = try httpx.Socket.createForAddress(addr);
    defer client.close();

    try client.connect(addr);
    try client.writeAll("ping");

    var out_buf: [64]u8 = undefined;
    const rn = try client.read(&out_buf);
    std.debug.print("Recv: {s}\n", .{out_buf[0..rn]});
}
```

## Run

```bash
zig build run-tcp_local
```

## What to Verify

- Listener binds on `127.0.0.1` with ephemeral port.
- Client connects and sends `ping`.
- Server replies with `pong`.
- Both sockets and thread shut down cleanly.
