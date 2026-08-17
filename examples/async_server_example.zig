//! Thread Pool and Async Task Offloading HTTP Server Example
//!
//! Demonstrates:
//! 1. Starting a server with a configured thread pool (worker pool).
//! 2. Handling requests concurrently on the worker threads.

const std = @import("std");
const httpx = @import("httpx");

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

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from the worker pool thread!");
}

fn asyncTaskHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    // Simulate a slow blocking computation/I/O task.
    httpx.sleepMs(50);
    return ctx.text("Processed blocking task on worker thread pool!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Thread Pool HTTP Server Example ===\n\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .threads = 4,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/", helloHandler);
    try server.get("/async", asyncTaskHandler);

    std.debug.print("Server Configuration:\n", .{});
    std.debug.print("  Host: {s}\n", .{server.config.host});
    std.debug.print("  Port: {d}\n", .{server.config.port});
    std.debug.print("  Worker Threads: {d}\n", .{server.config.threads});
    std.debug.print("  ThreadPool enabled: {}\n", .{server.executor != null});

    std.debug.print("\nRegistered routes:\n", .{});
    std.debug.print("  GET  /        -> helloHandler\n", .{});
    std.debug.print("  GET  /async   -> asyncTaskHandler (simulates slow workload)\n", .{});

    const server_thread = try server.listenInBackground();

    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    const hello_url = try std.fmt.allocPrint(allocator, "{s}/", .{base_url});
    defer allocator.free(hello_url);
    const async_url = try std.fmt.allocPrint(allocator, "{s}/async", .{base_url});
    defer allocator.free(async_url);

    var resp1 = try client.get(hello_url, .{});
    defer resp1.deinit();
    std.debug.print("\nGET / -> status: {d}, body: {s}\n", .{ resp1.status.code, resp1.text() orelse "" });

    var resp2 = try client.get(async_url, .{});
    defer resp2.deinit();
    std.debug.print("GET /async -> status: {d}, body: {s}\n", .{ resp2.status.code, resp2.text() orelse "" });

    std.debug.print("\nThread pool demo complete!\n", .{});

    server.stop();
    server_thread.join();
}
