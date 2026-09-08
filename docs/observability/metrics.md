# Metrics & Monitoring

HTTPX includes a production-grade, thread-safe metrics registry compatible with Prometheus text format (v0.0.4) and zero-allocation point-in-time snapshots.

## Metrics Types

* **Counters (`httpx.Counter`)**: Monotonically increasing 64-bit unsigned values (e.g. total requests, bytes sent, error counts).
* **Gauges (`httpx.Gauge`)**: Instantly varying 64-bit signed values (e.g. active connections, active requests) with underflow-safe atomic operations.
* **Histograms (`httpx.Histogram`)**: High-resolution latency tracking using 11 standard Prometheus buckets (`0.005`, `0.01`, `0.025`, `0.05`, `0.1`, `0.25`, `0.5`, `1.0`, `2.5`, `5.0`, `10.0` seconds + `+Inf`), total count, and cumulative sum in seconds with nanosecond precision.

## Server Live Metrics Endpoint

HTTPX servers automatically track connections, requests, methods, status code classes (`2xx`, `3xx`, `4xx`, `5xx`), bytes in/out, durations, and errors. You can mount a dynamic Prometheus `/metrics` endpoint with a single call:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // Mount live Prometheus /metrics endpoint
    try server.metrics("/metrics");

    server.get("/", struct {
        fn handle(ctx: *httpx.Context) !void {
            try ctx.text("Hello World!");
        }
    }.handle);

    try server.run();
}
```

Visiting `http://localhost:8080/metrics` dynamically generates standard Prometheus exposition text with `# HELP` and `# TYPE` headers:

```text
# HELP http_requests_total Total HTTP requests served.
# TYPE http_requests_total counter
http_requests_total{method="GET",status="2xx"} 1420
http_requests_total{method="POST",status="2xx"} 85

# HELP http_connections_active Number of active TCP connections.
# TYPE http_connections_active gauge
http_connections_active 4

# HELP http_request_duration_seconds HTTP request latency distribution.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 1240
http_request_duration_seconds_bucket{le="0.010"} 1380
http_request_duration_seconds_bucket{le="0.025"} 1410
http_request_duration_seconds_bucket{le="0.050"} 1450
http_request_duration_seconds_bucket{le="0.100"} 1490
http_request_duration_seconds_bucket{le="+Inf"} 1505
http_request_duration_seconds_sum 3.421500
http_request_duration_seconds_count 1505
```

## Point-in-Time Snapshots

HTTPX provides lightweight, lock-free snapshots to inspect metrics without heap allocation or blocking workers:

```zig
// Server snapshot with uptime, rate, and connection stats
const snap = server.snapshot();
std.debug.print("Uptime: {d}ms\n", .{snap.uptime_ms});
std.debug.print("Total requests: {d}\n", .{snap.requests_total});
std.debug.print("Error rate: {d:.2}%\n", .{snap.errorRate() * 100.0});
std.debug.print("Throughput: {d:.2} req/sec\n", .{snap.requestsPerSecond()});
std.debug.print("Active connections: {d}\n", .{snap.active_connections});

// Raw metrics snapshot
const m_snap = server.metricsSnapshot();
std.debug.print("Avg latency: {d:.3}ms\n", .{m_snap.averageLatencyMs()});
```

## Standalone Registry

You can also use `httpx.metrics.MetricsRegistry` standalone in custom applications, background workers, or microservices:

```zig
var reg = httpx.metrics.MetricsRegistry.init();

reg.requests_total.inc();
reg.active_connections.inc();
reg.recordRequest("GET", 200, 12_500_000); // 12.5ms duration

var buf: [4096]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try reg.writePrometheus(fbs.writer());
```

## Related

* [Observability: Events](/observability/events)
* [Example: Metrics Server](/examples/metrics-server)

