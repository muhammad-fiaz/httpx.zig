# Network API

Low-level networking abstractions for TCP, UDP, and socket operations. This module provides cross-platform socket wrappers that work on all supported platforms (Linux, Windows, macOS, FreeBSD) and architectures (x86_64, aarch64, i386, arm).

## Platform Support

| Platform | TCP | UDP | TLS | Unix Sockets |
|----------|-----|-----|-----|--------------|
| Linux | ✅ | ✅ | ✅ | ✅ |
| Windows | ✅ | ✅ | ✅ | ❌ |
| macOS | ✅ | ✅ | ✅ | ✅ |
| FreeBSD | ✅ | ✅ | ✅ | ✅ |

## TCP Socket

Cross-platform TCP socket wrapper for reliable, ordered, connection-oriented communication.

### Creating a TCP Socket

```zig
const httpx = @import("httpx");

// Create a TCP socket
var socket = try httpx.Socket.create(.tcp);
defer socket.close();

// Connect to a server
const addr = try std.net.Address.parseIp4("93.184.216.34", 80);
try socket.connect(addr);

// Send data
const sent = try socket.send("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");

// Receive response
var buffer: [4096]u8 = undefined;
const received = try socket.recv(&buffer);
std.debug.print("Received: {s}\n", .{buffer[0..received]});
```

### Socket Structure

```zig
pub const Socket = struct {
    handle: posix.socket_t,
    connected: bool,
    
    pub fn create(protocol: Protocol) !Socket
    pub fn connect(self: *Socket, addr: net.Address) !void
    pub fn send(self: *Socket, data: []const u8) !usize
    pub fn sendAll(self: *Socket, data: []const u8) !void
    pub fn recv(self: *Socket, buffer: []u8) !usize
    pub fn close(self: *Socket) void
};
```

### TCP Socket Methods

| Method | Description |
|--------|-------------|
| `create(protocol)` | Creates a new socket (TCP or UDP) |
| `connect(addr)` | Connects to a remote address |
| `send(data)` | Sends data, returns bytes sent |
| `sendAll(data)` | Reliably sends all data |
| `recv(buffer)` | Receives data into buffer |
| `close()` | Closes the connection |

### TCP Socket Options

```zig
// Disable Nagle's algorithm for low-latency
try socket.setNoDelay(true);

// Set receive timeout (milliseconds)
try socket.setRecvTimeout(5000);

// Set send timeout (milliseconds)  
try socket.setSendTimeout(5000);

// Enable TCP Keep-Alive
try socket.setKeepAlive(true);

// Set socket buffer sizes
try socket.setRecvBufferSize(65536);
try socket.setSendBufferSize(65536);
```

## TCP Listener

Server-side TCP listener for accepting incoming connections.

### Basic TCP Server

```zig
const httpx = @import("httpx");

// Create and bind listener
const addr = try std.net.Address.parseIp4("0.0.0.0", 8080);
var listener = try httpx.TcpListener.init(addr);
defer listener.deinit();

std.debug.print("Listening on port 8080...\n", .{});

// Accept connections in a loop
while (true) {
    const conn = try listener.accept();
    defer conn.socket.close();
    
    std.debug.print("Client connected from {}\n", .{conn.addr});
    
    // Handle client...
    var buffer: [1024]u8 = undefined;
    const n = try conn.socket.recv(&buffer);
    _ = try conn.socket.send("HTTP/1.1 200 OK\r\n\r\nHello!");
}
```

### TcpListener Methods

| Method | Description |
|--------|-------------|
| `init(addr)` | Creates listener bound to address |
| `accept()` | Accepts incoming connection |
| `getLocalAddress()` | Returns bound address |
| `deinit()` | Closes the listener |

## UDP Socket

Cross-platform UDP datagram socket for connectionless communication. Use UDP for:

- Low-latency applications (gaming, VoIP)
- DNS queries
- QUIC transport (HTTP/3)
- Broadcast/multicast
- Custom binary protocols

### Basic UDP Communication

```zig
const httpx = @import("httpx");

// Create UDP socket
var sock = try httpx.UdpSocket.create();
defer sock.close();

// Bind to local address
try sock.bind(try std.net.Address.parseIp4("0.0.0.0", 0));
const local = try sock.getLocalAddress();
std.debug.print("Bound to port {}\n", .{local.getPort()});

// Send datagram
const dest = try std.net.Address.parseIp4("127.0.0.1", 9000);
_ = try sock.sendTo(dest, "Hello UDP!");

// Receive datagram
var buffer: [1024]u8 = undefined;
const result = try sock.recvFrom(&buffer);
std.debug.print("Received {d} bytes from {}\n", .{result.n, result.addr});
```

### UDP Echo Server

```zig
const httpx = @import("httpx");

var sock = try httpx.UdpSocket.create();
defer sock.close();

try sock.bind(try std.net.Address.parseIp4("0.0.0.0", 9000));
std.debug.print("UDP server listening on port 9000\n", .{});

var buffer: [1024]u8 = undefined;
while (true) {
    const result = try sock.recvFrom(&buffer);
    std.debug.print("Received: {s}\n", .{buffer[0..result.n]});
    
    // Echo back
    _ = try sock.sendTo(result.addr, buffer[0..result.n]);
}
```

### UdpSocket Methods

| Method | Description |
|--------|-------------|
| `create()` | Creates IPv4 UDP socket |
| `createV4()` | Creates IPv4 UDP socket |
| `createV6()` | Creates IPv6 UDP socket |
| `bind(addr)` | Binds to local address |
| `connect(addr)` | Sets default destination |
| `send(data)` | Sends to connected address |
| `sendTo(addr, data)` | Sends to specific address |
| `recv(buffer)` | Receives from connected peer |
| `recvFrom(buffer)` | Receives with sender address |
| `getLocalAddress()` | Returns bound address |
| `close()` | Closes the socket |

### UDP Socket Options

```zig
// Allow address reuse (for multiple listeners)
try sock.setReuseAddr(true);

// Set receive timeout
try sock.setRecvTimeout(5000);

// Set send timeout
try sock.setSendTimeout(5000);

// Enable broadcast
try sock.setBroadcast(true);
```

## Address Resolution

### Parsing IP Addresses

```zig
// IPv4
const ipv4 = try std.net.Address.parseIp4("192.168.1.1", 8080);

// IPv6
const ipv6 = try std.net.Address.parseIp6("::1", 8080);

// Auto-detect
const addr = try std.net.Address.resolveIp("example.com", 80);
```

### Address Structure

```zig
pub const Address = union(enum) {
    ipv4: std.net.Ip4Address,
    ipv6: std.net.Ip6Address,
    
    pub fn getPort(self: Address) u16
    pub fn format(...) 
};
```

## TLS Integration

For secure connections (HTTPS, TLS), httpx.zig uses Zig's standard library TLS (`std.crypto.tls`). The socket module provides I/O adapters for seamless TLS integration.

### TLS Client Example

```zig
const httpx = @import("httpx");
const std = @import("std");

// Create TCP socket
var socket = try httpx.Socket.create(.tcp);
defer socket.close();

// Connect to server
const addr = try std.net.Address.resolveIp("example.com", 443);
try socket.connect(addr);

// Wrap with TLS
var tls_client = try std.crypto.tls.Client.init(socket.reader(), socket.writer(), .{
    .host = "example.com",
});

// Send HTTPS request
try tls_client.writer().writeAll("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");

// Read response
var buffer: [4096]u8 = undefined;
const n = try tls_client.reader().read(&buffer);
```

See [TLS API](/api/tls) for more details on TLS configuration and certificate handling.

## Use with HTTP Protocols

### HTTP/1.1 over TCP

```zig
// Standard HTTP uses TCP
var client = httpx.Client.init(allocator, io);
defer client.deinit();

const response = try client.get("http://example.com/api", .{});
```

### HTTP/3 over UDP (QUIC)

HTTP/3 uses QUIC transport over UDP. See the [Protocol API](/api/protocol) for QUIC framing:

```zig
// QUIC uses UDP for transport
var udp = try httpx.UdpSocket.create();
defer udp.close();

// QUIC packet handling (see protocol module)
const packet = try httpx.quic.LongHeader.decode(data);
```

## Error Handling

Network operations can fail for various reasons:

```zig
const result = socket.connect(addr) catch |err| switch (err) {
    error.ConnectionRefused => {
        std.debug.print("Server not accepting connections\n", .{});
        return;
    },
    error.NetworkUnreachable => {
        std.debug.print("Network is down\n", .{});
        return;
    },
    error.TimedOut => {
        std.debug.print("Connection timed out\n", .{});
        return;
    },
    else => return err,
};
```

### Common Errors

| Error | Description |
|-------|-------------|
| `ConnectionRefused` | Server not listening |
| `NetworkUnreachable` | No route to host |
| `TimedOut` | Operation timed out |
| `AddressInUse` | Port already bound |
| `ConnectionReset` | Peer closed connection |
| `WouldBlock` | Non-blocking operation would block |

## See Also

- [Client API](/api/client) - High-level HTTP client
- [Server API](/api/server) - HTTP server implementation
- [Protocol API](/api/protocol) - HTTP/2, HTTP/3, QUIC
- [TLS API](/api/tls) - TLS/SSL configuration
