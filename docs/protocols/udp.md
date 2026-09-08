# UDP Sockets

HTTPX wraps User Datagram Protocol (UDP) sockets to power non-blocking DNS lookups and QUIC/HTTP/3 datagram delivery.

## Characteristics

* **Connectionless**: Zero handshake delay; packets are dispatched directly to destination addresses.
* **Message-Oriented**: Preserves datagram boundaries; messages are received in discrete packets up to the Path MTU (typically 1200-1472 bytes).
* **Integrated with `std.Io`**: Event polling handles concurrent UDP socket reading without worker thread starvation.

## Socket Primitives

```zig
pub const Socket = struct {
    pub fn bind(io: std.Io, address: *const Address) !Socket;
    pub fn sendTo(self: *Socket, bytes: []const u8, dest: *const Address) !usize;
    pub fn recvFrom(self: *Socket, buffer: []u8, from: *Address) !usize;
    pub fn close(self: *Socket) void;
};
```

## Related

* [Protocol: QUIC](/protocols/quic)
* [Protocol: DNS](/protocols/dns)
* [Example: UDP Local](/examples/udp-local)
