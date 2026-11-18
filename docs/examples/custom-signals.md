# Custom Signals

Per-server signal policy with application hooks. Demonstrates independent
termination masks, a thread-safe telemetry hook, and a multi-server process.

```zig
//! Custom per-server signal policy with application hooks.
//!
//! Press Ctrl+C once to drain both servers, twice to expedite.

const std = @import("std");
const httpx = @import("httpx");

/// Shared, thread-safe application state owned by the process, not by a
/// server. Hooks run on the signal manager's notification thread, so every
/// field is updated with atomics.
const Telemetry = struct {
    interrupts: std.atomic.Value(u32) = .init(0),
    terminations: std.atomic.Value(u32) = .init(0),
    consoleEvents: std.atomic.Value(u32) = .init(0),
};

fn observe(event: httpx.server.SignalEvent, context: ?*anyopaque) void {
    const telemetry: *Telemetry = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .interrupt => _ = telemetry.interrupts.fetchAdd(event.count, .acq_rel),
        .terminate => _ = telemetry.terminations.fetchAdd(event.count, .acq_rel),
        .close, .logoff, .shutdown => {
            _ = telemetry.consoleEvents.fetchAdd(event.count, .acq_rel);
        },
    }

    // Normal thread context: logging and metrics are safe here.
    std.log.info("signal kind={s} count={d}", .{ @tagName(event.kind), event.count });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var telemetry: Telemetry = .{};

    // Public API server: full default policy, custom observer, 30s drain.
    var api = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .signals = .{
            .drainMs = 30_000,
            .onSignal = observe,
            .ctx = &telemetry,
        },
    });
    defer api.deinit();

    // Background worker: only SIGTERM and Windows shutdown drain it.
    var worker = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 9090,
        .signals = .{
            .interrupt = false,
            .terminate = true,
            .close = false,
            .shutdown = true,
            .drainMs = 60_000,
            .onSignal = observe,
            .ctx = &telemetry,
        },
    });
    defer worker.deinit();

    const WorkerThread = struct {
        fn run(server: *httpx.Server) void {
            server.run();
        }
    };
    const workerThread = try std.Thread.spawn(.{}, WorkerThread.run, .{&worker});

    // Both servers subscribe to one process-wide backend. Each receives only
    // the kinds its mask enables.
    api.run();

    // `run()` returned after a signal requested shutdown. Drain the worker too.
    worker.shutdown();
    workerThread.join();

    std.log.info("interrupts={d} terminations={d} console={d}", .{
        telemetry.interrupts.load(.acquire),
        telemetry.terminations.load(.acquire),
        telemetry.consoleEvents.load(.acquire),
    });
}
```

## Behavior

* `api` reacts to Ctrl+C, `SIGTERM`, and Windows close/shutdown.
* `worker` reacts only to `SIGTERM` and Windows shutdown; Ctrl+C leaves it
  running.
* The first signal requests a graceful drain and waits up to the configured
  deadline. A second signal stops immediately.
* `observe` runs on the notification thread in normal context and only uses
  atomics, so it is safe alongside concurrent requests.

## How to Run

```bash
zig build example-custom-signals   # compile only
zig build run-custom-signals       # real process signals
```

Full source: `examples/customSignals.zig`.

## Related

* [Guide: Signals & Graceful Shutdown](/guide/signals)
* [Example: Manual Signals](/examples/manual-signals)
