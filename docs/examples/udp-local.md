# UDP Local

Run a local UDP send/receive round trip over loopback.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var recv_sock = try httpx.UdpSocket.create();
    defer recv_sock.close();

    try recv_sock.setReuseAddr(true);
    try recv_sock.bind(try std.net.Address.parseIp("127.0.0.1", 0));
    const recv_addr = try recv_sock.getLocalAddress();

    var send_sock = try httpx.UdpSocket.create();
    defer send_sock.close();

    _ = try send_sock.sendTo(recv_addr, "hello over udp");

    var buf: [256]u8 = undefined;
    const got = try recv_sock.recvFrom(&buf);
    std.debug.print("Recv: {s}\n", .{buf[0..got.n]});
    std.debug.print("From: {f}\n", .{got.addr});
}
```

## Run

```bash
zig build run-udp_local
```

## What to Verify

- UDP bind succeeds on local interface.
- Datagram is sent and received on loopback.
- Both sockets close cleanly.
