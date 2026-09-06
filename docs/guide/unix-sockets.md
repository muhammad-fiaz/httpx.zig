# Unix Domain Sockets Guide

`httpx.zig` supports Unix domain sockets (AF_UNIX) for same-machine IPC, bypassing the network stack entirely for lower latency than TCP loopback.

## What Unix Domain Sockets Are

Unix domain sockets are an IPC mechanism that allows processes on the same machine to communicate via a socket file path rather than an IP address and port. Because they skip the network card, TCP header processing, and routing, they offer lower latency and higher throughput than localhost TCP.

Use them when:
- You need fast IPC between processes on the same host (e.g., a web server talking to an app server).
- You want to avoid exposing a port on the network interface.
- You are writing a reverse proxy or sidecar that runs alongside another process.

## Platform Availability

Unix domain sockets are supported on:
- Linux
- macOS
- Windows 10 version 1803 and later

The implementation in `src/net/unix.zig` handles the Windows/Winsock path automatically.

## `MAX_PATH_LEN`

The maximum socket path length is `108` bytes (matching the `sockaddr_un.path` field size on Linux and macOS). Paths at or beyond this limit return `error.PathTooLong`.

```zig
const httpx = @import("httpx");
std.debug.print("max path: {d}\n", .{httpx.MAX_PATH_LEN});
```

## Server: `UnixListener`

```zig
const httpx = @import("httpx");

var listener = try httpx.UnixListener.init("app.sock");
defer listener.deinit(); // closes fd and deletes the socket file

while (true) {
    const accepted = try listener.accept();
    // accepted.socket is a UnixSocket
    var buf: [1024]u8 = undefined;
    const n = try accepted.socket.read(&buf);
    std.debug.print("received: {s}\n", .{buf[0..n]});
    try accepted.socket.writeAll("HTTP/1.1 200 OK\r\n\r\nHello");
    accepted.socket.close();
}
```

`UnixListener.init` removes any existing socket file at the path before binding.

`UnixListener` methods:

| Method | Description |
|--------|-------------|
| `init(path)` | Bind and listen on `path` |
| `accept()` | Accept a connection, returns `UnixAccepted { socket: UnixSocket }` |
| `deinit()` | Close listener and delete socket file |

## Client: `UnixClient`

```zig
const socket = try httpx.UnixClient.connect("app.sock");
defer socket.close();

try socket.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

var buf: [4096]u8 = undefined;
const n = try socket.read(&buf);
std.debug.print("response: {s}\n", .{buf[0..n]});
```

`UnixClient.connect(path)` returns a `UnixSocket` directly.

## `UnixSocket` Methods

| Method | Description |
|--------|-------------|
| `writeAll(data)` | Send all bytes, retrying on partial writes |
| `read(buf)` | Read bytes into buf, returns count |
| `readAll(buf)` | Read until buf is full or EOF |
| `close()` | Close the socket |

## High-Level HTTP Client Integration

The httpx high-level client can route HTTP requests over a Unix socket:

```zig
var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
    .withUnixSocket("app.sock"));
defer client.deinit();

var resp = try client.get("http://localhost/health", .{});
defer resp.deinit();
```

## High-Level HTTP Server Integration

Bind the httpx server to a Unix socket path instead of a port:

```zig
var server = httpx.Server.initWithConfig(allocator, .{
    .unix_path = "app.sock",
});
defer server.deinit();

try server.get("/health", struct {
    fn h(ctx: *httpx.Context) anyerror!httpx.Response {
        return ctx.text("ok");
    }
}.h);

try server.listen();
```

## Comparison with TCP Loopback

| Property | Unix Socket | TCP Loopback |
|----------|------------|--------------|
| Latency | Lower (no TCP overhead) | Higher |
| Throughput | Higher | Lower |
| Accessible remotely | No | Yes (on same port) |
| Path length limit | 108 bytes | N/A |
| Windows support | 10+ (1803+) | All versions |
| Authentication | File system permissions | Port-based |

## Full Working Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "httpx-demo.sock";

    // Start server in background
    var server = httpx.Server.initWithConfig(allocator, .{ .unix_path = path });
    defer server.deinit();

    try server.get("/ping", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.text("pong");
        }
    }.h);

    const t = try server.listenInBackground();
    defer t.join();
    defer server.stop();

    // Wait briefly for startup
    std.Thread.sleep(50_000_000);

    // Connect as client
    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withUnixSocket(path));
    defer client.deinit();

    var resp = try client.get("http://localhost/ping", .{});
    defer resp.deinit();

    std.debug.print("status: {d}\n", .{resp.status.code});
    std.debug.print("body: {s}\n", .{resp.text() orelse ""});
}
```
