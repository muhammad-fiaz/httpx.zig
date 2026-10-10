# Example: Metrics Server

Demonstrates metricsServer.zig using the canonical HTTPX API.

## Complete Example

```zig
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
        .maxConnections = 5,
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

    var urlBuf: [128]u8 = undefined;

    // 1. Call API endpoint
    const urlData = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/api/data", .{port});
    var res1 = try client.get(urlData, .{});
    std.debug.print("GET /api/data -> status={d}, body={s}\n", .{ res1.status, res1.body });
    res1.deinit();

    // 2. Fetch live Prometheus metrics from /metrics
    const urlMetrics = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/metrics", .{port});
    var resMetrics = try client.get(urlMetrics, .{});
    std.debug.print("GET /metrics -> status={d}, size={d} bytes\n", .{ resMetrics.status, resMetrics.body.len });
    std.debug.print("--- Live Prometheus Output ---\n{s}\n------------------------------\n", .{resMetrics.body});
    resMetrics.deinit();

    // 3. Inspect in-memory snapshot
    const snap = server.snapshot();
    std.debug.print("Server snapshot: uptime={d}ms, requestsTotal={d}, errorRate={d:.2}%\n", .{
        snap.uptimeMs,
        snap.requestsTotal,
        snap.errorRate() * 100.0,
    });

    server.requestShutdown();
    t.join();
    std.debug.print("Metrics server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>Metrics Example</h1>", .contentType = "text/html" };
}

fn dataHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"data\":\"some value\",\"count\":42}", .contentType = "application/json" };
}
```

## Expected Output

```text
Metrics server running on http://127.0.0.1:54321
GET /api/data -> status=200, body={"data":"some value","count":42}
GET /metrics -> status=200, size=1234 bytes
--- Live Prometheus Output ---
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total 2
------------------------------
Server snapshot: uptime=150ms, requestsTotal=2, errorRate=0.00%
Metrics server verification completed successfully.
```

The port, byte sizes, Prometheus body, and snapshot counters/timings vary per run; the line shapes above follow the example's print statements exactly.

## How to Run

```bash
zig build run-metrics-server
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
