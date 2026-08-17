//! Concurrent Requests Example
//!
//! Demonstrates:
//! 1. Running concurrent HTTP requests in parallel using different concurrency modes.
//! 2. Single-threaded, Multi-threaded, and Explicit Executor workers.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello!");
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

    std.debug.print("=== Concurrent Requests Example ===\n\n", .{});

    const port = try pickFreeTcpPort();

    // 1. Start a local loopback mock server
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .keep_alive = false,
    });
    defer server.deinit();
    try server.get("/data", helloHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    // 2. Build a batch of requests
    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/data", .{port});
    defer allocator.free(base_url);

    var builder = httpx.concurrency.BatchBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.get(base_url);
    _ = try builder.get(base_url);
    _ = try builder.get(base_url);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    // 3. Mode: multi_thread (implicit background workers)
    std.debug.print("Executing batch of {d} requests via multi_thread mode (implicit workers)...\n", .{builder.count()});
    const mt_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .multi_thread,
        .workers = 2,
    });
    defer {
        for (mt_results) |*r| r.deinit();
        allocator.free(mt_results);
    }
    std.debug.print("Successful results: {d}/{d}\n\n", .{ httpx.successfulCount(mt_results), mt_results.len });

    // 4. Mode: single_thread (sequential execution on calling thread)
    std.debug.print("Executing batch of {d} requests via single_thread mode (sequential)...\n", .{builder.count()});
    const st_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .single_thread,
    });
    defer {
        for (st_results) |*r| r.deinit();
        allocator.free(st_results);
    }
    std.debug.print("Successful results: {d}/{d}\n\n", .{ httpx.successfulCount(st_results), st_results.len });

    // 5. Mode: explicit_workers (explicit Executor thread pool)
    std.debug.print("Executing batch of {d} requests via explicit_workers mode...\n", .{builder.count()});
    var exec = httpx.Executor.initWithConfig(allocator, .{ .num_threads = 3 });
    defer exec.deinit();
    try exec.start();

    const ex_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .explicit_workers,
        .executor = &exec,
    });
    defer {
        for (ex_results) |*r| r.deinit();
        allocator.free(ex_results);
    }
    std.debug.print("Successful results: {d}/{d}\n\n", .{ httpx.successfulCount(ex_results), ex_results.len });

    std.debug.print("Demo complete!\n", .{});

    server.stop();
    server_thread.join();
}
