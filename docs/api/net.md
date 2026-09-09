# Network API

Low-level networking primitives for TCP and UDP across Linux, Windows, and
macOS (`src/sockets/`, `src/net/`).

## Platform Support

| Platform | TCP | UDP | TLS | Notes |
|----------|-----|-----|-----|-------|
| Linux | ✅ | ✅ | ✅ | `MSG_NOSIGNAL` prevents SIGPIPE on broken connections |
| Windows | ✅ | ✅ | ✅ | Winsock-native connects with full error mapping |
| macOS | ✅ | ✅ | ✅ | |

## TCP (`httpx.tcp`)

Cross-platform stream socket abstraction (`Socket`, `Listener`, `IoContext`).

### Basic Usage

```zig
const std = @import("std");
const httpx = @import("httpx");

var socket = try httpx.tcp.connect(io, "93.184.216.34", 80);
defer socket.close();

try socket.writeAll("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");

var buf: [4096]u8 = undefined;
const n = try socket.read(&buf);
std.debug.print("{s}\n", .{buf[0..n]});
```

### Methods

| Method | Description |
|--------|-------------|
| `connect(io, host, port)` | Connect to an IP-literal host |
| `connectAddress(io, addr)` | Connect to a parsed `Address` (winsock-fast on Windows) |
| `connectAddressStream(io, addr)` | Connect via `std.Io.net` (required for TLS) |
| `Socket.read(buf)` / `Socket.writeAll(data)` | One-shot receive / send-all |
| `Socket.close()` / `drainThenClose()` / `shutdownWrite()` | Teardown (idempotent) |
| `Socket.isAlive()` | Local close-guard state |
| `Socket.netSocketHandle()` | Raw handle for tuning |
| `setTimeouts(sock, ms)` / `setNoDelay(sock)` / `setKeepAlive(sock, idleSecs)` | Socket tuning |
| `Listener.bind(io, port)` / `bindAddress(io, addr)` | Bind (`0` = ephemeral) |
| `Listener.accept(listener, io)` | Accept one connection |
| `Listener.localPort(listener)` | Actual bound port |
| `Listener.close(listener, io)` | Close listener |
| `IoContext.init(gpa)` / `deinit()` | Runtime IO context for tests and tools |

### Connect Errors

| Error | Description |
|-------|-------------|
| `ConnectionRefused` | Server not listening |
| `NetworkUnreachable` / `HostUnreachable` | No route to host |
| `TimedOut` | Operation timed out |
| `PermissionDenied` | Operation not permitted |
| `Unexpected` | Unmapped platform error |

## UDP (`httpx.udp.UdpSocket`)

Connectionless datagrams (used by DNS/QUIC/custom protocols).

```zig
var sock = try httpx.udp.UdpSocket.bind(io, 0);
defer sock.close();
try sock.sendTo(&dest, "ping");
const msg = try sock.receive(&buf);
```

| Method | Description |
|--------|-------------|
| `bind(io, port)` | Bind `0.0.0.0:port` (`0` = ephemeral) |
| `sendTo(dest, data)` / `send(data)` | Send (explicit or default destination) |
| `receive(buffer)` | Receive datagram + source address |
| `close()` | Close socket |

## Address Utilities (`httpx.Address`)

- `Address.loopback4(port)` / `loopback6(port)` / `unspecified4(port)` / `unspecified6(port)`
- `Address.parse(text, defaultPort)` — split `host[:port]`
- `address.parseIp(text)` — IP-literal to `Address`
- `format` / `formatBuf` / `formatWithPort` / `toString` / `toStd` / `fromStd`

DNS resolution goes through `client.resolve(...)`, `httpx.resolve.Resolver`,
and the client DNS cache (`ClientConfig.dnsCache`); SOCKS/proxy dialing via
`httpx.socks5` / `httpx.proxy`; reachability via `httpx.connectivity`.

## See Also

- [Client API](/api/client) - High-level HTTP client
- [Server API](/api/server) - HTTP server implementation
- [Protocol API](/api/protocol) - HTTP/2, HTTP/3, QUIC
- [TLS API](/api/tls) - TLS/SSL configuration
