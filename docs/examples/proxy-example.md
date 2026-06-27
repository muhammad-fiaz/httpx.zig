# Proxy and Reverse Proxy

Demonstrates how to use client-side forward proxying and server-side reverse proxying.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn mockBackendHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from Mock Backend!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_port = 45233;
    const proxy_port = 45234;

    // 1. Start the mock backend server
    var backend_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = backend_port,
        .keep_alive = false,
    });
    defer backend_server.deinit();
    try backend_server.get("/backend-data", mockBackendHandler);

    const backend_thread = try std.Thread.spawn(.{}, struct {
        fn run(server: *httpx.Server) void {
            server.listen() catch {};
        }
    }.run, .{&backend_server});
    defer backend_thread.join();
    defer backend_server.stop();

    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};

    // 2. Start the proxy server with reverseProxy middleware
    var proxy_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = proxy_port,
        .keep_alive = false,
    });
    defer proxy_server.deinit();

    try proxy_server.use(httpx.reverseProxy("http://127.0.0.1:45233"));

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn run(server: *httpx.Server) void {
            server.listen() catch {};
        }
    }.run, .{&proxy_server});
    defer proxy_thread.join();
    defer proxy_server.stop();

    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};

    // 3. Setup client with proxy configuration pointing to the proxy server
    const client_config = httpx.ClientConfig.defaults()
        .withProxy(.{
            .host = "127.0.0.1",
            .port = proxy_port,
        });

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    // 4. Request the mock backend path through the proxy.
    const target_url = "http://127.0.0.1:45233/backend-data";
    var response = try client.get(target_url, .{});
    defer response.deinit();

    std.debug.print("Proxy response status: {d}\n", .{response.status.code});
    std.debug.print("Proxy response body: {s}\n", .{response.text() orelse ""});
}
```

## Run

```bash
zig build run-proxy_example
```

## What to Verify

- Client requests are intercepted and successfully routed through the proxy server.
- The reverse proxy middleware forwards the request to the target mock backend server.
- Response body text returned matches the mock backend response.
