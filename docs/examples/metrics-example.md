# Metrics and Observability Example

Request/response counters, status classes, and latency histograms with
`httpx.Metrics`. See `examples/metrics_server.zig`.

```zig
var m = httpx.Metrics{};

// Record traffic.
m.recordRequest();
m.recordRequestMethod("GET");
m.recordResponseFull(200, 1_200_000, 512); // status, latency_ns, bytes
m.recordResponseFull(500, 4_500_000, 64);

const snap = m.snapshot();
std.debug.print("Total Requests: {d}\n", .{snap.requestsTotal});
std.debug.print("Error Rate:     {d:.1}%\n", .{snap.errorRate() * 100.0});
std.debug.print("Avg Latency:    {d:.3}ms\n", .{snap.averageLatencyMs()});
```

Servers record automatically; mount `try server.metrics("/metrics");` for
live Prometheus exposition, or read `server.snapshot()` /
`server.metricsSnapshot()`.

## Run

```bash
zig build run-metrics-server
```

## What to Verify

- Counters, status classes, and latency samples accumulate.
- `/metrics` renders Prometheus text with the live values.
