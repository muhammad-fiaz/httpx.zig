# TCP Sockets

HTTPX provides zero-allocation abstractions over native OS Transmission Control Protocol (TCP) sockets, utilizing Zig's `std.Io` framework (`httpx.tcp`).

## Platform Backends

* **Windows**: Winsock2 (`ws2_32.lib`) native connects with full error mapping.
* **Linux**: POSIX stream sockets.
* **macOS**: BSD sockets.

## Socket Operations (`httpx.tcp.Socket`)

```zig
var socket = try httpx.tcp.connect(io, "93.184.216.34", 80);
defer socket.close();

try socket.writeAll("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
var buf: [4096]u8 = undefined;
const n = try socket.read(&buf);
```

| Member | Description |
|--------|-------------|
| `connect(io, host, port)` | Connect to an IP-literal host |
| `connectAddress(io, addr)` | Connect to a parsed `Address` |
| `connectAddressStream(io, addr)` | Connect via `std.Io.net` (for TLS) |
| `read(buf)` / `writeAll(data)` | Receive / send-all |
| `close()` / `drainThenClose()` / `shutdownWrite()` | Idempotent teardown |
| `isAlive()` | Local close-guard state |
| `netSocketHandle()` | Raw handle for tuning |

## Listener (`httpx.tcp.Listener`)

```zig
var listener = try httpx.tcp.Listener.bind(io, 0);
defer listener.close(io);
const port = listener.localPort();
var conn = try listener.accept(io);
defer conn.close();
```

## Socket Tuning in HTTPX

* `setTimeouts(sock, ms)`: `SO_RCVTIMEO` / `SO_SNDTIMEO`.
* `setNoDelay(sock)`: `TCP_NODELAY`.
* `setKeepAlive(sock, idleSecs)`: keep-alive with idle timeout.

## Related

* [API: Net](/api/net)
* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Example: TCP Local](/examples/tcp-local)
