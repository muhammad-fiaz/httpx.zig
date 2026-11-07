# Network API

Low-level networking primitives for TCP and UDP across Linux, Windows, and
macOS (`src/sockets/`, `src/net/`).

## Platform Support

| Platform | TCP | UDP | TLS | Notes |
|----------|-----|-----|-----|-------|
| Linux | ✅ | ✅ | ✅ | `MSG_NOSIGNAL` prevents SIGPIPE on broken connections |
| Windows | ✅ | ✅ | ✅ | Winsock-native connects with full error mapping |
| macOS | ✅ | ✅ | ✅ | |

## TCP (`httpx.socket.tcp`)

Cross-platform stream sockets (`init` for the listening side, `connect`
for the client side; use `std.Io.Threaded.global_single_threaded.io()` in tests).

### Basic Usage

```zig
const std = @import("std");
const httpx = @import("httpx");

var socket = try httpx.socket.tcp.connect(io, "93.184.216.34", 80);
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
| `init(allocator, io, .{ .port = 0 })` / `init(allocator, io, .{ .address = addr })` | Bind (`0` = ephemeral) |
| `Listener.accept(listener, io)` | Accept one connection |
| `Listener.localPort(listener)` | Actual bound port |
| `Listener.close(listener, io)` | Close listener |
| `io` | `std.Io` | Explicit I/O, obtained as `std.Io.Threaded.global_single_threaded.io()` |

### Connect Errors

| Error | Description |
|-------|-------------|
| `ConnectionRefused` | Server not listening |
| `NetworkUnreachable` / `HostUnreachable` | No route to host |
| `TimedOut` | Operation timed out |
| `PermissionDenied` | Operation not permitted |
| `Unexpected` | Unmapped platform error |

## UDP (`httpx.socket.udp`)

Connectionless datagrams (used by DNS/QUIC/custom protocols).

```zig
var sock = try httpx.socket.udp.init(allocator, io, .{});
defer sock.close();
try sock.sendTo(&dest, "ping");
const msg = try sock.receive(&buf);
```

| Method | Description |
|--------|-------------|
| `init(allocator, io, .{})` / `init(allocator, io, .{ .port = 53 })` | Bind `0.0.0.0:port` (`0` = ephemeral); `.{}` is the default |
| `bindIp6(io, port)` | Bind `[::]:port` for IPv6 peers |
| `bindAddress(io, addr)` | Bind an explicit IPv4 or IPv6 `Address` |
| `sendTo(dest, data)` / `send(data)` | Send (explicit or default destination) |
| `receive(buffer)` | Receive datagram + source address |
| `close()` | Close socket |

`receive`/`receiveTimeout` return `error.DatagramTruncated` when a datagram is
larger than the supplied buffer instead of silently returning a partial
payload. The POSIX backend reports this via `MSG_TRUNC`; Windows does not
surface the flag, so truncated datagrams are still returned there.

## Address Utilities (`httpx.Address`)

- `Address.loopback4(port)` / `loopback6(port)` / `unspecified4(port)` / `unspecified6(port)`
- `Address.parse(text, defaultPort)` — split `host[:port]`
- `Address.parseIp(text)` — IP-literal to `Address` (no instance needed)
- `format` / `formatBuf` / `formatWithPort` / `toString` / `toStd` / `fromStd`

DNS resolution goes through `client.resolve(...)`, `httpx.net.resolve.Resolver`,
and the client DNS cache (`.dnsCache` in the `Client.init` options); SOCKS/proxy dialing via
`httpx.socks5` / `httpx.proxy`; reachability via `httpx.connectivity`.

## See Also

- [Client API](/api/client) - High-level HTTP client
- [Server API](/api/server) - HTTP server implementation
- [Protocol API](/api/protocol) - HTTP/2, HTTP/3, QUIC
- [TLS API](/api/tls) - TLS/SSL configuration
