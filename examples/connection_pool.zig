//! Connection Pool Example
//!
//! Demonstrates HTTP connection pooling by making multiple requests
//! to a local server and showing connection reuse behavior.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn poolHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .status = "ok" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Connection Pool Example ===\n\n", .{});

    // 1. Start a local server to demonstrate pooling
    std.debug.print("--- Starting Local Server ---\n", .{});
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();

    try server.get("/pool/status", poolHandler);
    try server.get("/pool/data", poolHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(200);
    const port = server.config.port;
    std.debug.print("  Server listening on port {d}\n\n", .{port});

    // 2. Create a client with pool configuration
    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withPoolLimits(20, 5));
    defer client.deinit();

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    // 3. Show initial pool state
    std.debug.print("--- Initial Pool State ---\n", .{});
    var stats = client.poolStats();
    std.debug.print("  Total connections: {d}\n", .{stats.total});
    std.debug.print("  Active connections: {d}\n", .{stats.active});
    std.debug.print("  Idle connections: {d}\n\n", .{stats.idle});

    // 4. Make first request (creates new connection)
    std.debug.print("--- First Request (new connection) ---\n", .{});
    const url1 = try std.fmt.allocPrint(allocator, "{s}/pool/status", .{base_url});
    defer allocator.free(url1);

    var resp1 = client.get(url1, .{}) catch |err| {
        std.debug.print("Request failed: {}\n", .{err});
        return;
    };
    defer resp1.deinit();

    std.debug.print("  Status: {d}\n", .{resp1.status.code});
    stats = client.poolStats();
    std.debug.print("  Pool total: {d}, active: {d}, idle: {d}\n\n", .{ stats.total, stats.active, stats.idle });

    // 5. Make second request (reuses connection from pool)
    std.debug.print("--- Second Request (reuses connection) ---\n", .{});
    const url2 = try std.fmt.allocPrint(allocator, "{s}/pool/data", .{base_url});
    defer allocator.free(url2);

    var resp2 = client.get(url2, .{}) catch |err| {
        std.debug.print("Request failed: {}\n", .{err});
        return;
    };
    defer resp2.deinit();

    std.debug.print("  Status: {d}\n", .{resp2.status.code});
    stats = client.poolStats();
    std.debug.print("  Pool total: {d}, active: {d}, idle: {d}\n\n", .{ stats.total, stats.active, stats.idle });

    // 6. Multiple concurrent requests
    std.debug.print("--- Multiple Concurrent Requests ---\n", .{});
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const url = try std.fmt.allocPrint(allocator, "{s}/pool/status", .{base_url});
        defer allocator.free(url);

        var resp = client.get(url, .{}) catch |err| {
            std.debug.print("  Request {d} failed: {}\n", .{ i + 1, err });
            continue;
        };
        defer resp.deinit();
        std.debug.print("  Request {d}: status {d}\n", .{ i + 1, resp.status.code });
    }

    stats = client.poolStats();
    std.debug.print("\n--- Final Pool State ---\n", .{});
    std.debug.print("  Total connections: {d}\n", .{stats.total});
    std.debug.print("  Active connections: {d}\n", .{stats.active});
    std.debug.print("  Idle connections: {d}\n", .{stats.idle});
    std.debug.print("  Host connections (127.0.0.1:{d}): {d}\n", .{ port, client.hostPoolConnectionCount("127.0.0.1", port) });

    std.debug.print("\n=== Connection Pool Example Complete ===\n", .{});

    server.stop();
    server_thread.join();
}
