//! Proxy Client & Reverse Proxy Server Example
//!
//! Demonstrates:
//! 1. Starting a loopback HTTP backend server and a separate proxy-forwarding server.
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

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Proxy Support Example ===\n\n", .{});

    const backend_port = try pickFreeTcpPort();
    const proxy_port = try pickFreeTcpPort();

    // 1. Start the mock backend server.
    var backend_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = backend_port,
        .keep_alive = false,
    });
    defer backend_server.deinit();
    try backend_server.get("/backend-data", mockBackendHandler);

    const backend_thread = try backend_server.listenInBackground();

    sleepMs(100);

    // 2. Start a proxy-forwarding server.
    //    We use the high-level httpx.reverseProxy comptime middleware.
    //    A fixed comptime URL cannot hold the dynamic port, so we use
    //    a direct-client forwarding handler via server.global() instead.
    var proxy_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = proxy_port,
        .keep_alive = false,
    });
    defer proxy_server.deinit();

    // Build the backend base URL as a fixed buffer so it is available to the handler.
    var backend_url_buf: [64]u8 = undefined;
    const backend_url = try std.fmt.bufPrint(&backend_url_buf, "http://127.0.0.1:{d}", .{backend_port});

    // Register reverse proxy using comptime-known local address via global handler.
    // The handler closes over backend_url_buf which lives on main's stack frame.
    const ForwardCtx = struct {
        var target: []const u8 = "";
    };
    ForwardCtx.target = backend_url;

    // Register the forwarding handler as the global fallback so all
    // unmatched paths are forwarded to the backend.
    proxy_server.global(struct {
        fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
            var fwd = httpx.Client.initWithConfig(ctx.allocator, httpx.ClientConfig.defaults()
                .withTimeouts(httpx.Timeouts.fast())
                .withRetryPolicy(httpx.RetryPolicy.noRetry())
                .withKeepAlive(false));
            defer fwd.deinit();

            const path = ctx.request.uri.path;
            const full = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ForwardCtx.target, path });
            defer ctx.allocator.free(full);

            return fwd.request(ctx.request.method, full, .{});
        }
    }.handler);

    const proxy_thread = try proxy_server.listenInBackground();

    sleepMs(100);

    // 3. Client configured to route through the proxy server.
    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withProxy(.{
        .host = "127.0.0.1",
        .port = proxy_port,
    });

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    // 4. Request the backend path through the proxy.
    const target_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/backend-data", .{backend_port});
    defer allocator.free(target_url);

    std.debug.print("Sending request to {s} via proxy at 127.0.0.1:{d}...\n", .{ target_url, proxy_port });
    var response = try client.get(target_url, .{});
    defer response.deinit();

    std.debug.print("Proxy response status: {d}\n", .{response.status.code});
    std.debug.print("Proxy response body: {s}\n", .{response.text() orelse ""});

    proxy_server.stop();
    proxy_thread.join();
    backend_server.stop();
    backend_thread.join();
}
