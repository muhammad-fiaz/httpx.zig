# UDP Local

Local UDP send/receive round trip over loopback with
`httpx.udp.UdpSocket`.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var recvSock = try httpx.udp.UdpSocket.bind(io, 0);
    defer recvSock.close();

    var sendSock = try httpx.udp.UdpSocket.bind(io, 0);
    defer sendSock.close();

    var dest = try std.Io.net.IpAddress.parseIp4("127.0.0.1", recvSock.socket.address.port);
    try sendSock.sendTo(&dest, "hello over udp");

    var buf: [256]u8 = undefined;
    const got = try recvSock.receive(&buf);
    std.debug.print("Recv: {s}\n", .{got.data});
}
```

## What to Verify

- UDP bind succeeds on the local interface.
- The datagram is sent and received on loopback.
