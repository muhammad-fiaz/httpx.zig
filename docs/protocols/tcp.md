# TCP Sockets

HTTPX provides zero-allocation abstractions over native OS Transmission Control Protocol (TCP) sockets, utilizing Zig's `std.Io` framework.

## Platform Backends

* **Windows**: Winsock2 (`ws2_32.lib`) with Asynchronous File Descriptor (AFD) handles.
* **Linux**: POSIX stream sockets with non-blocking polling and `epoll` compatibility.
* **macOS**: BSD sockets with `kqueue` event notifications.

## Socket Operations

```zig
pub const Socket = struct {
    inner: SocketInner,

    pub fn read(self: *Socket, buffer: []u8) !usize;
    pub fn writeAll(self: *Socket, bytes: []const u8) !void;
    pub fn close(self: *Socket) void;
    pub fn setTimeouts(handle: Socket.Handle, timeout_ms: u32) void;
    pub fn setNoDelay(handle: Socket.Handle, enabled: bool) void;
};
```

## Socket Tuning in HTTPX

* `TCP_NODELAY`: Enabled by default to disable Nagle's algorithm and eliminate buffering latency on small request packets.
* `SO_KEEPALIVE`: Enabled to detect severed connections on long-idle pooled sockets.

## Related

* [API: Net](/api/net)
* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Example: TCP Local](/examples/tcp-local)
