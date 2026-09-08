const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .max_connections = 5,
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.get("/api/data", dataHandler);
    try server.metrics("/metrics");

    const port = server.localPort();
    std.debug.print("Metrics server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;

    // 1. Call API endpoint
    const url_data = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/data", .{port});
    var res1 = try client.get(url_data, .{});
    std.debug.print("GET /api/data -> status={d}, body={s}\n", .{ res1.status, res1.body });
    res1.deinit();

    // 2. Fetch live Prometheus metrics from /metrics
    const url_metrics = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/metrics", .{port});
    var res_metrics = try client.get(url_metrics, .{});
    std.debug.print("GET /metrics -> status={d}, size={d} bytes\n", .{ res_metrics.status, res_metrics.body.len });
    std.debug.print("--- Live Prometheus Output ---\n{s}\n------------------------------\n", .{res_metrics.body});
    res_metrics.deinit();

    // 3. Inspect in-memory snapshot
    const snap = server.snapshot();
    std.debug.print("Server snapshot: uptime={d}ms, requests_total={d}, error_rate={d:.2}%\n", .{
        snap.uptime_ms,
        snap.requests_total,
        snap.errorRate() * 100.0,
    });

    server.requestShutdown();
    t.join();
    std.debug.print("Metrics server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>Metrics Example</h1>", .content_type = "text/html" };
}

fn dataHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"data\":\"some value\",\"count\":42}", .content_type = "application/json" };
}
