const std = @import("std");
const httpx = @import("httpx");

fn backendHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .source = "backend",
        .message = "Response from upstream",
    });
}

fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("healthy");
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
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

    const backend_port = try pickFreeTcpPort();
    var backend = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = backend_port,
    });
    defer backend.deinit();

    try backend.get("/api/data", backendHandler);
    try backend.get("/health", healthHandler);

    const backend_thread = try backend.listenInBackground();
    sleepMs(100);

    std.debug.print("  Backend on port {d}\n", .{backend_port});

    const proxy_port = try pickFreeTcpPort();
    var proxy = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = proxy_port,
    });
    defer proxy.deinit();

    const backend_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{backend_port});
    defer allocator.free(backend_url);

    try proxy.use(httpx.reverseProxyRuntime(backend_url));

    const proxy_thread = try proxy.listenInBackground();
    sleepMs(100);

    std.debug.print("  Proxy on port {d} -> backend {d}\n", .{ proxy_port, backend_port });

    const rt_proxy_port = try pickFreeTcpPort();
    var rt_proxy = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = rt_proxy_port,
    });
    defer rt_proxy.deinit();

    try rt_proxy.use(httpx.reverseProxyRuntime(backend_url));

    const rt_proxy_thread = try rt_proxy.listenInBackground();
    sleepMs(100);

    std.debug.print("  Runtime proxy on port {d} -> backend {d}\n", .{ rt_proxy_port, backend_port });

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const proxy_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/data", .{proxy_port});
    defer allocator.free(proxy_url);

    var resp = try client.get(proxy_url, .{});
    defer resp.deinit();
    std.debug.print("  GET /api/data -> status: {d}\n", .{resp.status.code});
    if (resp.text()) |body| {
        std.debug.print("  Body: {s}\n", .{body});
    }

    rt_proxy.stop();
    rt_proxy_thread.join();
    proxy.stop();
    proxy_thread.join();
    backend.stop();
    backend_thread.join();
}
