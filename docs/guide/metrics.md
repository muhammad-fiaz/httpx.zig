# Metrics and Observability Guide

`httpx.zig` includes a lightweight, allocation-free metrics module for tracking requests, responses, latency, and connection counts using atomic operations.

## Overview

`Metrics` uses `std.atomic.Value` for all counters, making it safe to call from multiple threads without locks. `MetricsSnapshot` is a plain struct copy taken at a point in time, safe to read without synchronization.

## Initializing Metrics

```zig
const httpx = @import("httpx");

// Basic metrics instance
var metrics = httpx.Metrics.init();

// With a custom callback for external integrations
var metrics = httpx.Metrics.initWithCallback(myCallbackFn);
```

## Recording Events

### Requests and responses

```zig
metrics.recordRequest();                         // increment request counter
metrics.recordResponse(200, 1024, 1_500_000);   // status, bytes, latency_ns
metrics.recordResponse(500, 0, 800_000);
metrics.recordError();                           // increment error counter
```

`recordResponse` automatically buckets the status code into `responses_2xx`, `responses_3xx`, `responses_4xx`, or `responses_5xx` and updates latency min/max/total.

### Connections

```zig
metrics.connectionOpened();   // +1 to active_connections
metrics.connectionClosed();   // -1 to active_connections
```

### Bytes sent

```zig
metrics.recordBytesSent(4096);
```

## Taking a Snapshot

`snapshot()` reads all atomic values and returns a `MetricsSnapshot`:

```zig
const snap = metrics.snapshot();

std.debug.print("requests={d} responses={d}\n", .{
    snap.total_requests, snap.total_responses,
});
std.debug.print("2xx={d} 4xx={d} 5xx={d}\n", .{
    snap.responses_2xx, snap.responses_4xx, snap.responses_5xx,
});
std.debug.print("avg_latency={d}ns\n", .{snap.avg_latency_ns});
std.debug.print("error_rate={d:.2}\n", .{snap.errorRate()});
std.debug.print("success_rate={d:.2}\n", .{snap.successRate()});
```

### `MetricsSnapshot` fields

| Field | Type | Description |
|-------|------|-------------|
| `total_requests` | `u64` | Total recorded requests |
| `total_responses` | `u64` | Total recorded responses |
| `active_connections` | `i64` | Current open connections |
| `total_errors` | `u64` | Total errors |
| `bytes_sent` | `u64` | Total bytes sent |
| `bytes_received` | `u64` | Total bytes received |
| `responses_2xx` | `u64` | 2xx response count |
| `responses_3xx` | `u64` | 3xx response count |
| `responses_4xx` | `u64` | 4xx response count |
| `responses_5xx` | `u64` | 5xx response count |
| `avg_latency_ns` | `u64` | Average response latency (nanoseconds) |
| `min_latency_ns` | `u64` | Minimum observed latency |
| `max_latency_ns` | `u64` | Maximum observed latency |

### `MetricsSnapshot` methods

| Method | Returns | Description |
|--------|---------|-------------|
| `totalRequests()` | `u64` | Return `total_requests` |
| `totalResponses()` | `u64` | Return `total_responses` |
| `activeConnections()` | `i64` | Return `active_connections` |
| `errors()` | `u64` | Return `total_errors` |
| `errorRate()` | `f64` | `total_errors / total_requests`, 0.0 if no requests |
| `successRate()` | `f64` | `responses_2xx / total_responses`, 0.0 if no responses |
| `redirectRate()` | `f64` | `responses_3xx / total_responses` |
| `clientErrorRate()` | `f64` | `responses_4xx / total_responses` |
| `serverErrorRate()` | `f64` | `responses_5xx / total_responses` |
| `throughputBytesPerResponse()` | `u64` | Average bytes per response |

## Custom Callbacks

Register a callback to forward events to external monitoring systems:

```zig
fn myCallback(event: httpx.MetricsEvent) void {
    switch (event) {
        .request => { /* increment external counter */ },
        .response => |r| {
            std.debug.print("status={d} latency={d}ns\n", .{
                r.status, r.latency_ns,
            });
        },
        .err => { /* alert on errors */ },
        .connection_open, .connection_close => {},
        .bytes_sent => |n| _ = n,
    }
}

var metrics = httpx.Metrics.initWithCallback(myCallback);
```

`MetricsEvent` is a tagged union with variants: `request`, `response` (with `status`, `bytes`, `latency_ns`), `bytes_sent`, `err`, `connection_open`, `connection_close`.

## Thread Safety

All `Metrics` methods use `.monotonic` atomic operations. This means:
- Individual counter updates are atomic and safe from any thread.
- `snapshot()` reads each counter independently; there is no global snapshot lock, so values from different fields may come from slightly different instants. For most observability use cases this is fine.
- If you need a strictly consistent snapshot, take it from a single thread or add your own mutex.

## Resetting Counters

```zig
metrics.reset(); // sets all counters back to zero
```

## Exposing a Metrics Endpoint

```zig
const httpx = @import("httpx");

var global_metrics = httpx.Metrics.init();

fn metricsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const snap = global_metrics.snapshot();
    return ctx.json(.{
        .requests = snap.total_requests,
        .responses = snap.total_responses,
        .errors = snap.total_errors,
        .success_rate = snap.successRate(),
        .error_rate = snap.errorRate(),
        .avg_latency_ms = snap.avg_latency_ns / 1_000_000,
        .active_connections = snap.active_connections,
    });
}
```

## Full Working Example

```zig
const std = @import("std");
const httpx = @import("httpx");

var metrics = httpx.Metrics.init();

fn apiHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    metrics.recordRequest();
    const t0 = std.time.nanoTimestamp();

    const resp = try ctx.json(.{ .hello = "world" });

    const elapsed: u64 = @intCast(std.time.nanoTimestamp() - t0);
    metrics.recordResponse(200, resp.body.len, elapsed);
    return resp;
}

fn metricsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const snap = metrics.snapshot();
    return ctx.json(.{
        .requests = snap.total_requests,
        .success_rate = snap.successRate(),
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/api", apiHandler);
    try server.get("/metrics", metricsHandler);
    try server.listen();
}
```
