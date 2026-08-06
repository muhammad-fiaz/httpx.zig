//! Logging Callback Example
//!
//! Demonstrates how to set up custom logging functions for both server and client.
//! Shows how to route logs to an external logging library (simulated)
//! and demonstrates silent mode (no logs) vs verbose mode.

const std = @import("std");
const httpx = @import("httpx");

// Simulated external logging library callback
fn externalLogger(level: httpx.LogLevel, message: []const u8) void {
    const prefix = switch (level) {
        .debug => "[EXT-DEBUG]",
        .info => "[EXT-INFO]",
        .warn => "[EXT-WARN]",
        .err => "[EXT-ERROR]",
    };
    std.debug.print("{s} {s}\n", .{ prefix, message });
}

// Silent logger that suppresses all output
fn silentLogger(level: httpx.LogLevel, message: []const u8) void {
    _ = level;
    _ = message;
    // Do nothing - silent mode
}

// Custom logger with timestamp
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

    std.debug.print("=== Logging Callback Example ===\n\n", .{});

    // 1. Server with external logger
    std.debug.print("--- Server with External Logger ---\n", .{});
    const port1 = try pickFreeTcpPort();
    var server1 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port1,
        .log_fn = externalLogger,
    });
    defer server1.deinit();

    try server1.get("/hello", handler);

    const server_thread1 = try server1.listenInBackground();
    defer server_thread1.join();
    defer server1.stop();

    sleepMs(100);

    // Client with external logger
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

    // 2. Server with silent logger (no logs)
    std.debug.print("--- Server with Silent Logger (No Logs) ---\n", .{});
    const port2 = try pickFreeTcpPort();
    var server2 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port2,
        .log_fn = silentLogger,
    });
    defer server2.deinit();

    try server2.get("/hello", handler);

    const server_thread2 = try server2.listenInBackground();
    defer server_thread2.join();
    defer server2.stop();

    sleepMs(100);

    // Client with silent logger
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

    // 3. Server with timestamp logger (verbose mode)
    std.debug.print("--- Server with Timestamp Logger (Verbose) ---\n", .{});
    const port3 = try pickFreeTcpPort();
    var server3 = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port3,
        .log_fn = timestampLogger,
    });
    defer server3.deinit();

    try server3.get("/hello", handler);

    const server_thread3 = try server3.listenInBackground();
    defer server_thread3.join();
    defer server3.stop();

    sleepMs(100);

    // Client with timestamp logger
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

    std.debug.print("=== Logging Callback Example Complete ===\n", .{});
}
