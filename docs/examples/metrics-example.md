# Metrics and Observability Example

Request/response counters, status classes, and latency histograms with
`httpx.Metrics`. See `examples/metricsServer.zig`.

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

## Expected Output

```text
Total Requests: 2
Error Rate:     50.0%
Avg Latency:    2.850ms
```

The values reflect the recorded traffic (2 requests, one 200 and one 500 in the snippet); counts, rates, and latencies vary with the actual requests recorded.

## Run

```bash
zig build run-metrics-server
```

## What to Verify

- Counters, status classes, and latency samples accumulate.
- `/metrics` renders Prometheus text with the live values.
