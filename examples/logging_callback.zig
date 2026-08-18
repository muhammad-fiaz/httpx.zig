const std = @import("std");
const httpx = @import("httpx");

fn externalLogger(level: httpx.LogLevel, message: []const u8) void {
    const prefix = switch (level) {
        .debug => "[EXT-DEBUG]",
        .info => "[EXT-INFO]",
        .warn => "[EXT-WARN]",
        .err => "[EXT-ERROR]",
    };
    std.debug.print("{s} {s}\n", .{ prefix, message });
}

fn silentLogger(level: httpx.LogLevel, message: []const u8) void {
    _ = level;
    _ = message;
}

fn timestampLogger(level: httpx.LogLevel, message: []const u8) void {
    const prefix = switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
    std.debug.print("[{s}] {s}\n", .{ prefix, message });
}

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .message = "Hello, World!" });
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

    const port1 = try pickFreeTcpPort();
    var server1 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port1,
        .log_fn = externalLogger,
    });
    defer server1.deinit();

    try server1.get("/hello", handler);

    const server_thread1 = try server1.listenInBackground();

    sleepMs(100);

    var client1 = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withLogFn(externalLogger));
    defer client1.deinit();

    const url1 = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/hello", .{port1});
    defer allocator.free(url1);

    var resp1 = try client1.get(url1, .{});
    defer resp1.deinit();
    std.debug.print("  Response status: {d}\n\n", .{resp1.status.code});

    const port2 = try pickFreeTcpPort();
    var server2 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port2,
        .log_fn = silentLogger,
    });
    defer server2.deinit();

    try server2.get("/hello", handler);

    const server_thread2 = try server2.listenInBackground();

    sleepMs(100);

    var client2 = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withLogFn(silentLogger));
    defer client2.deinit();

    const url2 = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/hello", .{port2});
    defer allocator.free(url2);

    var resp2 = try client2.get(url2, .{});
    defer resp2.deinit();
    std.debug.print("  Response status: {d} (no logs from server/client)\n\n", .{resp2.status.code});

    const port3 = try pickFreeTcpPort();
    var server3 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port3,
        .log_fn = timestampLogger,
    });
    defer server3.deinit();

    try server3.get("/hello", handler);

    const server_thread3 = try server3.listenInBackground();

    sleepMs(100);

    var client3 = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withLogFn(timestampLogger));
    defer client3.deinit();

    const url3 = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/hello", .{port3});
    defer allocator.free(url3);

    var resp3 = try client3.get(url3, .{});
    defer resp3.deinit();
    std.debug.print("  Response status: {d}\n\n", .{resp3.status.code});

    server3.stop();
    server_thread3.join();
    server2.stop();
    server_thread2.join();
    server1.stop();
    server_thread1.join();
}
