# Metrics and Observability Example

Demonstrates how to collect, aggregate, and report performance and error metrics within your client/server programs using `httpx.zig`.

## Features Covered

- **Request/Response Counters**: Logging total requests and classifying responses by status class (2xx, 3xx, 4xx, 5xx).
- **Latency Tracking**: Measuring minimum, average, and maximum response times in milliseconds.
- **Traffic Logging**: Tracking bytes sent and bytes received.
- **Observability Snapshots**: Exporting metrics snapshots with success rates, error rates, and resetting collections.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var m = httpx.Metrics.init();

    // Record some sample traffic data
    m.recordRequest();
    m.recordResponse(200, 512, 1200); // status, bytes, latency_ns
    m.recordResponse(500, 64, 4500);

    const snap = m.snapshot();
    std.debug.print("Total Requests: {d}\n", .{snap.totalRequests()});
    std.debug.print("Success Rate:   {d:.1}%\n", .{snap.successRate() * 100.0});
    std.debug.print("Avg Latency:    {d}ns\n", .{snap.avgLatencyNs()});
}
```

## Running the Example

Run the pre-configured metrics example:

```bash
zig build run-all-metrics_example
```
