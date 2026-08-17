//! Metrics and Observability Example
//!
//! Demonstrates httpx.zig's built-in metrics collection:
//! - Recording requests, responses, errors, and connection events
//! - Per-status-class counters (2xx, 3xx, 4xx, 5xx)
//! - Latency tracking (min/avg/max)
//! - Byte counters
//! - Snapshot and reset
//! - Error rate and success rate helpers
//! - Integration with a live local server

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    return (try listener.getLocalAddress()).getPort();
}

fn printSnapshot(snap: *const httpx.MetricsSnapshot) void {
    std.debug.print(
        "Metrics Snapshot:\n" ++
            "  Requests:   {d}\n" ++
            "  Responses:  {d}  (2xx={d} 3xx={d} 4xx={d} 5xx={d})\n" ++
            "  Errors:     {d}\n" ++
            "  Active:     {d} connections\n" ++
            "  Bytes In:   {d}  Out: {d}\n" ++
            "  Latency:    avg={d}ns  min={d}ns  max={d}ns\n",
        .{
            snap.totalRequests(),
            snap.totalResponses(),
            snap.responses2xx(),
            snap.responses3xx(),
            snap.responses4xx(),
            snap.responses5xx(),
            snap.errors(),
            snap.activeConnections(),
            snap.bytesReceived(),
            snap.bytesSent(),
            snap.avgLatencyNs(),
            snap.minLatencyNs(),
            snap.maxLatencyNs(),
        },
    );
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Metrics and Observability Example ===\n\n", .{});

    // 1. Manual metric recording
    std.debug.print("--- Manual Recording ---\n", .{});

    var m = httpx.Metrics.init();

    // Simulate 10 requests
    for (0..10) |_| m.recordRequest();

    // 6 x 200 OK, 2 x 404, 2 x 500
    for (0..6) |i| m.recordResponse(200, 512 + i * 100, 1000 + i * 200);
    for (0..2) |_| m.recordResponse(404, 128, 300);
    for (0..2) |_| m.recordResponse(500, 64, 5000);

    m.recordBytesSent(8192);
    m.recordError();
    m.recordError();
    m.connectionOpened();
    m.connectionOpened();
    m.connectionOpened();
    m.connectionClosed();

    const snap = m.snapshot();
    printSnapshot(&snap);

    std.debug.print("Error rate:   {d:.1}%\n", .{snap.errorRate() * 100.0});
    std.debug.print("Success rate: {d:.1}%\n\n", .{snap.successRate() * 100.0});

    // 2. Reset
    std.debug.print("--- Reset ---\n", .{});
    m.reset();
    const after_reset = m.snapshot();
    std.debug.print("After reset - requests: {d}, responses: {d}\n\n", .{
        after_reset.totalRequests(), after_reset.totalResponses(),
    });

    // 3. Live server integration
    std.debug.print("--- Live Server + Metrics ---\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.get("/ok", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.json(.{ .status = "ok" });
        }
    }.h);
    try server.get("/error", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.status(500).text("internal error");
        }
    }.h);

    const t = try server.listenInBackground();
    sleepMs(100);

    // Record metrics alongside real requests
    var live = httpx.Metrics.init();
    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    const ok_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/ok", .{port});
    defer allocator.free(ok_url);
    const err_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/error", .{port});
    defer allocator.free(err_url);

    live.connectionOpened();
    for (0..3) |_| {
        live.recordRequest();
        var r = try client.get(ok_url, .{});
        defer r.deinit();
        live.recordResponse(r.status.code, @intCast(r.text().?.len), 1500);
    }

    live.recordRequest();
    var r_err = try client.get(err_url, .{});
    defer r_err.deinit();
    live.recordResponse(r_err.status.code, 14, 3000);
    live.recordError();
    live.connectionClosed();

    const live_snap = live.snapshot();
    printSnapshot(&live_snap);

    std.debug.print("2xx responses: {d}\n", .{live_snap.responses2xx()});
    std.debug.print("5xx responses: {d}\n", .{live_snap.responses5xx()});
    std.debug.print("Active conns:  {d}\n", .{live_snap.activeConnections()});

    std.debug.print("\n=== Metrics Example Complete ===\n", .{});

    server.stop();
    t.join();
}
