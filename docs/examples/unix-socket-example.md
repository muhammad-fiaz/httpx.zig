# Unix Domain Socket Example

Demonstrates how to perform Inter-Process Communication (IPC) using HTTP over Unix domain sockets (AF_UNIX) for fast, zero-overhead same-machine messaging.

## Features Covered

- **Unix Socket Listening**: Binding an HTTP server to a local file/pipe socket path (`unix_path`).
- **Unix Socket Connecting**: Connecting a client directly to a Unix domain socket path (`withUnixSocket`).
- **Zero-Configuration Routing**: Matching HTTP routing rules and extracting parsed queries/JSON parameters over IPC.
- **Cross-Platform Compatibility**: Automatically running on Windows (using Winsock device pipes) and POSIX platforms.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const socket_path = "httpx-ipc.sock";

    // 1. Initialize and configure HTTP Server on Unix Socket
    var server = httpx.Server.initWithConfig(allocator, .{
        .unix_path = socket_path,
    });
    defer server.deinit();

    try server.get("/ipc-status", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.json(.{ .status = "connected", .transport = "unix_domain_socket" });
        }
    }.h);

    const thread = try server.listenInBackground();
    defer thread.join();
    defer server.stop();

    // 2. Initialize HTTP Client with unix_socket_path
    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withUnixSocket(socket_path)
    );
    defer client.deinit();

    // Make request over Unix Socket
    var resp = try client.get("http://localhost/ipc-status", .{});
    defer resp.deinit();

    std.debug.print("Response: {s}\n", .{resp.text().?});
}
```

## Running the Example

Run the pre-configured Unix Socket example:

```bash
zig build run-all-unix_socket_example
```
