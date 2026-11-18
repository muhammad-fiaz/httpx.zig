# Server Signals

Automatic Ctrl+C / `SIGTERM` handling with a bounded drain deadline. Two
independent servers in one process subscribe to the same process-wide backend.

```zig
//! Cross-platform signal handling and graceful shutdown.
//!
//! Build with: `zig build example-server-signals`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Automatic signal handling is on by default; no custom handler is needed.
    var primary = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .signals = .{ .drainMs = 10_000 },
    });
    defer primary.deinit();

    // Independent second server. Process-wide termination reaches every
    // server whose signal mask matches.
    var metrics = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 9090,
        .signals = .{ .drainMs = 5_000 },
    });
    defer metrics.deinit();

    const MetricsThread = struct {
        fn run(server: *httpx.Server) void {
            server.run();
        }
    };
    const metricsThread = try std.Thread.spawn(.{}, MetricsThread.run, .{&metrics});

    primary.run();

    // Both servers drained independently; join the second tier.
    metrics.shutdown();
    metricsThread.join();
}
```

## Behavior

* The first Ctrl+C or `SIGTERM` stops acceptance and lets active requests
  finish. The deadline monitor interrupts remaining I/O after the configured
  timeout.
* A second signal escalates to immediate shutdown.
* `primary` and `metrics` keep separate deadlines and subscriptions. Stopping
  one does not affect the other, and there is no global server pointer.

## How to Run

```bash
zig build example-server-signals   # compile only
zig build run-server-signals       # real process signals
```

## Related

* [Guide: Signals & Graceful Shutdown](/guide/signals)
* [Example: Custom Signals](/examples/custom-signals)
* [Example: Manual Signals](/examples/manual-signals)
