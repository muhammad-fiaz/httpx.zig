# Network API

Low-level networking primitives for TCP and UDP across Linux, Windows, macOS, and BSD-family targets.

## Platform Support

| Platform | TCP | UDP | TLS | Notes |
|----------|-----|-----|-----|-------|
| Linux | ✅ | ✅ | ✅ | `MSG_NOSIGNAL` prevents SIGPIPE on broken connections |
| Windows | ✅ | ✅ | ✅ | `WSAEWOULDBLOCK` handled via `select()` retry for large sends |
| macOS | ✅ | ✅ | ✅ | `MSG_NOSIGNAL` prevents SIGPIPE on broken connections |
| FreeBSD/NetBSD/OpenBSD | ✅ | ✅ | ✅ | |

## TCP Socket (`httpx.Socket`)

Cross-platform stream socket abstraction.

Canonical low-level I/O methods are `send(...)`, `sendAll(...)`, and `recv(...)`.
For stream-style ergonomics, compatibility aliases `write(...)`, `writeAll(...)`, and `read(...)` are also available.

### Basic Usage

```zig
const std = @import("std");
const httpx = @import("httpx");

var socket = try httpx.Socket.create();
defer socket.close();

const addr = try httpx.Address.parseIp("93.184.216.34", 80);
try socket.connect(addr);

try socket.writeAll("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");

var buf: [4096]u8 = undefined;
const n = try socket.read(&buf);
std.debug.print("{s}\n", .{buf[0..n]});
```

### Methods

| Method | Description |
|--------|-------------|
| `create()` | Create IPv4 TCP socket |
| `createV4()` / `createV6()` | Create explicit IPv4/IPv6 TCP socket |
| `createForAddress(addr)` | Create TCP socket matching address family |
| `connect(addr)` | Connect to remote endpoint |
| `connectHost(host, port)` | Resolve and connect |
| `connectEndpoint(endpoint, default_port)` | Parse `host:port` and connect |
| `send(data)` / `write(data)` | Send bytes |
| `sendAll(data)` / `writeAll(data)` | Send all bytes |
| `recv(buffer)` / `read(buffer)` | Receive bytes |
| `setOption(level, optname, value)` | Set raw socket option bytes |
| `shutdown(mode)` | Shutdown one or both halves (`recv`, `send`, `both`) |
| `shutdownRead()` / `shutdownWrite()` / `shutdownBoth()` | Convenience shutdown helpers |
| `bindHost(host, port)` | Resolve and bind local endpoint |
| `getLocalAddress()` | Return local bound/ephemeral address |
| `getPeerAddress()` | Return currently connected peer address |
| `close()` | Close socket |

### Shutdown Modes

`httpx.ShutdownMode` values:

- `recv`
- `send`
- `both`

### Socket Options

| Method | Description |
|--------|-------------|
| `setNoDelay(enable)` | TCP_NODELAY (disable Nagle when true) |
| `setKeepAlive(enable)` | SO_KEEPALIVE |
| `setReuseAddr(enable)` | SO_REUSEADDR |
| `setRecvTimeout(ms)` | SO_RCVTIMEO |
| `setSendTimeout(ms)` | SO_SNDTIMEO |
| `setRecvBufferSize(bytes)` | SO_RCVBUF |
| `setSendBufferSize(bytes)` | SO_SNDBUF |

## TCP Listener (`httpx.TcpListener`)

Server-side listener for accepting inbound TCP connections.

```zig
const std = @import("std");
const httpx = @import("httpx");

var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 8080));
defer listener.deinit();

const accepted = try listener.accept();
defer accepted.socket.close();
```

| Method | Description |
|--------|-------------|
| `init(addr)` | Bind/listen with default backlog |
| `initWithBacklog(addr, backlog)` | Bind/listen with explicit backlog |
| `initHost(host, port)` | Resolve host and bind/listen with default backlog |
| `initHostWithBacklog(host, port, backlog)` | Resolve host and bind/listen with custom backlog |
| `accept()` | Accept connection and return `{ socket, addr }` |
| `getLocalAddress()` | Return bound local address |
| `deinit()` | Close listener |

## Socket I/O Adapters

For TLS and low-level stream integration, the socket module also provides:

- `httpx.socket.SocketIoReader`
- `httpx.socket.SocketIoWriter`

These adapters bridge `httpx.Socket` to Zig's `std.Io.Reader` / `std.Io.Writer` interfaces.

## UDP Socket (`httpx.UdpSocket`)

Connectionless datagram abstraction (used by DNS/QUIC/custom protocols).

Canonical datagram I/O methods are `send(...)` and `recv(...)`.
For stream-style consistency across examples, compatibility aliases `write(...)` and `read(...)` are also available.

### Basic Usage

```zig
const std = @import("std");
const httpx = @import("httpx");

var recv_sock = try httpx.UdpSocket.create();
defer recv_sock.close();
try recv_sock.bind(try httpx.Address.parseIp("127.0.0.1", 0));

const recv_addr = try recv_sock.getLocalAddress();

var send_sock = try httpx.UdpSocket.create();
defer send_sock.close();
_ = try send_sock.sendTo(recv_addr, "ping");

var buf: [64]u8 = undefined;
const result = try recv_sock.recvFrom(&buf);
std.debug.print("{s}\n", .{buf[0..result.n]});
```

### Methods

| Method | Description |
|--------|-------------|
| `create()` / `createV4()` / `createV6()` | Create UDP socket |
| `createForAddress(addr)` | Create UDP socket matching address family |
| `bind(addr)` | Bind local address |
| `bindHost(host, port)` | Resolve and bind local endpoint |
| `connect(addr)` | Set default peer |
| `connectHost(host, port)` | Resolve and set default peer |
| `connectEndpoint(endpoint, default_port)` | Parse `host:port` and connect |
| `send(data)` / `write(data)` | Send to connected peer |
| `sendTo(addr, data)` | Send datagram to specific peer |
| `sendToHost(host, port, data)` | Resolve destination and send datagram |
| `recv(buffer)` / `read(buffer)` | Receive from connected peer |
| `recvFrom(buffer)` | Receive datagram + source address |
| `getLocalAddress()` | Return bound local address |
| `getPeerAddress()` | Return currently connected peer address |
| `close()` | Close socket |

### UDP Options

| Method | Description |
|--------|-------------|
| `setReuseAddr(enable)` | SO_REUSEADDR |
| `setBroadcast(enable)` | SO_BROADCAST |
| `setRecvTimeout(ms)` | SO_RCVTIMEO |
| `setSendTimeout(ms)` | SO_SNDTIMEO |
| `setRecvBufferSize(bytes)` | SO_RCVBUF |
| `setSendBufferSize(bytes)` | SO_SNDBUF |

## Address Utilities

`httpx.address` contains host/address helpers. At the root, aliases are also available:

- `httpx.resolveAddress(allocator, host, port)` — resolve hostname to a single address (takes an allocator for DNS lookup)
- `httpx.resolveAllAddresses(allocator, host, port)` — resolve hostname to all candidate addresses (caller frees returned slice)
- `httpx.parseHostAndPort(input, default_port)` — parse `"host:port"` style strings
- `httpx.parseAndResolveAddress(allocator, input, default_port)` — parse `"host:port"` and resolve to a concrete address
- `httpx.isIpAddress(input)` / `httpx.isIp4Address(input)` / `httpx.isIp6Address(input)`

Root-level network lifecycle aliases are also available:

- `httpx.netInit()`
- `httpx.netDeinit()`

```zig
const httpx = @import("httpx");

const addr = try httpx.resolveAddress(allocator, "example.com", 443);
const parsed = try httpx.parseHostAndPort("localhost:8080", 80);
```

## Convenience Aliases

At the root module:

- `httpx.TcpSocket` is an alias for `httpx.Socket`
- `httpx.DatagramSocket` is an alias for `httpx.UdpSocket`

## Examples

- [TCP Local](/examples/tcp-local)
- [UDP Local](/examples/udp-local)

## Error Handling

```zig
socket.connect(addr) catch |err| switch (err) {
    error.ConnectionRefused => std.debug.print("connection refused\n", .{}),
    error.NetworkUnreachable => std.debug.print("network unreachable\n", .{}),
    error.TimedOut => std.debug.print("timeout\n", .{}),
    else => return err,
};
```

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
