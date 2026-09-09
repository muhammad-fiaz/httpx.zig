# Metrics and Observability Guide

`httpx.zig` includes a lightweight, allocation-free metrics module for tracking requests, responses, latency, and connection counts using atomic operations.

## Overview

`httpx.Metrics` (`src/web/metrics/registry.zig`) uses `std.atomic.Value` for all counters, making it safe to call from multiple threads without locks. `snapshot()` returns a plain `MetricsSnapshot` struct copy, safe to read without synchronization. Servers record automatically into their own registry; the API below is for custom instrumentation.

## Recording events

```zig
var reg = httpx.Metrics{};
reg.recordRequest();                            // +1 requests, +1 in-flight
reg.recordRequestMethod("GET");                 // per-method count
reg.recordResponseFull(200, 1_500_000, 1024);   // status, latency_ns, bytes
reg.recordResponseFull(500, 800_000, 0);
reg.recordError();                              // +1 errors, -1 in-flight
reg.connectionOpened();                         // +1 activeConnections
reg.connectionClosed();                         // -1 activeConnections (underflow-safe)
reg.recordBytesIn(4096);
reg.reset();                                    // zero everything
```

## Taking a snapshot

`snapshot()` reads all atomic values and returns a `MetricsSnapshot`:

```zig
const snap = reg.snapshot();

std.debug.print("requests={d} responses={d}\n", .{
    snap.requestsTotal, snap.responsesTotal,
});
std.debug.print("2xx={d} 4xx={d} 5xx={d}\n", .{
    snap.status2xx, snap.status4xx, snap.status5xx,
});
std.debug.print("avg_latency={d:.3}ms\n", .{snap.averageLatencyMs()});
std.debug.print("error_rate={d:.2}\n", .{snap.errorRate()});
```

### `MetricsSnapshot` fields

| Field | Type | Description |
|-------|------|-------------|
| `requestsTotal` | `u64` | Total recorded requests |
| `responsesTotal` | `u64` | Total recorded responses |
| `errorsTotal` | `u64` | Total errors |
| `timeoutsTotal` | `u64` | Total timeouts |
| `bytesIn` / `bytesOut` | `u64` | Byte counters |
| `activeConnections` / `activeRequests` | `u64` | Current gauges |
| `status2xx` / `status3xx` / `status4xx` / `status5xx` | `u64` | Status class counts |
| `methodGet` / `methodPost` / `methodPut` / `methodDelete` / `methodPatch` / `methodHead` / `methodOptions` / `methodOther` | `u64` | Per-method counts |
| `durationCount` | `u64` | Latency sample count |
| `durationSumSeconds` | `f64` | Latency sum in seconds |
| `durationBuckets` | `[11]u64` | Cumulative histogram buckets |

### `MetricsSnapshot` methods

| Method | Returns | Description |
|--------|---------|-------------|
| `errorRate()` | `f64` | `errorsTotal / requestsTotal`, 0.0 if no requests |
| `averageLatencySeconds()` | `f64` | Mean latency in seconds |
| `averageLatencyMs()` | `f64` | Mean latency in milliseconds |

## Server snapshots

```zig
const snap = server.snapshot(); // ServerSnapshot: uptimeMs, gauges, totals
std.debug.print("uptime={d}ms rps={d:.1}\n", .{ snap.uptimeMs, snap.requestsPerSecond() });
const m = server.metricsSnapshot(); // raw MetricsSnapshot
```

Mount a live Prometheus endpoint with `try server.metrics("/metrics");`.

## Thread safety

All `Metrics` methods use `.monotonic` atomic operations:
- Individual counter updates are atomic and safe from any thread.
- `snapshot()` reads each counter independently; there is no global snapshot lock, so fields may come from slightly different instants. For most observability use cases this is fine.

## Prometheus exposition

`reg.render(writer)` emits Prometheus 0.0.4 text with standard snake_case wire
names (`http_requests_total`, `http_request_duration_seconds_bucket`, …).
See [Observability: Metrics](/observability/metrics).

## Full working example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 0 });
    defer server.deinit();

    try server.get("/api", apiHandler);
    try server.metrics("/metrics");

    const thread = try server.start();
    defer thread.join();
    defer server.requestShutdown();
}

fn apiHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .hello = "world" });
}
```
