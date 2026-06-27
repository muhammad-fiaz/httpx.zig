//! Proxy Client & Reverse Proxy Server Example
//!
//! Demonstrates:
//! 1. Starting a loopback HTTP server configured with a reverse proxy middleware
//!    forwarding requests to a mock backend.
//! 2. Making client requests using a Client configured to route through a proxy.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn mockBackendHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from Mock Backend!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Proxy Support Example ===\n\n", .{});

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

    const backend_thread = try backend_server.listenInBackground();
    defer backend_thread.join();
    defer backend_server.stop();

    sleepMs(20);

    // 2. Start the proxy server. We will use the reverseProxy middleware pointing to the mock backend.
    var proxy_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = proxy_port,
        .keep_alive = false,
    });
    defer proxy_server.deinit();

    // Register reverse proxy middleware
    try proxy_server.use(httpx.reverseProxy("http://127.0.0.1:45233"));

    const proxy_thread = try proxy_server.listenInBackground();
    defer proxy_thread.join();
    defer proxy_server.stop();

    sleepMs(20);

    // 3. Setup client with proxy configuration pointing to the proxy server
    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withProxy(.{
            .host = "127.0.0.1",
            .port = proxy_port,
        });

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    // 4. Request the mock backend path through the proxy.
    // The request to http://127.0.0.1:45233/backend-data will be routed via the proxy at 45234.
    const target_url = "http://127.0.0.1:45233/backend-data";

    std.debug.print("Sending request to {s} via proxy at 127.0.0.1:{d}...\n", .{ target_url, proxy_port });
    var response = try client.get(target_url, .{});
    defer response.deinit();

    std.debug.print("Proxy response status: {d}\n", .{response.status.code});
    std.debug.print("Proxy response body: {s}\n", .{response.text() orelse ""});
}
