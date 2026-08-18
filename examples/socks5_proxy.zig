const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn mockBackendHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .message = "Hello from backend!",
        .source = "socks5-proxy-example",
    });
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
    var backend_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = backend_port,
        .keep_alive = false,
    });
    defer backend_server.deinit();
    try backend_server.get("/data", mockBackendHandler);

    const backend_thread = try backend_server.listenInBackground();
    sleepMs(100);

    const proxy_port = 1080;

    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withProxy(.{
        .host = "127.0.0.1",
        .port = proxy_port,
        .kind = .socks5h,
        .username = "proxyuser",
        .password = "proxypass",
    });

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    const target_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/data", .{backend_port});
    defer allocator.free(target_url);

    var response = client.get(target_url, .{}) catch |err| {
        std.debug.print("\nRequest failed (expected if no proxy running): {}\n", .{err});
        return;
    };
    defer response.deinit();

    std.debug.print("Response status: {d}\n", .{response.status.code});
    if (response.text()) |body| {
        std.debug.print("Response body: {s}\n", .{body});
    }

    backend_server.stop();
    backend_thread.join();
}
