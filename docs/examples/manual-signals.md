# Manual Signals

Application-owned signal coordination using `httpx.signals` directly. The server
integration is disabled so the application controls shutdown, and the
subscription receives the server pointer as its context.

```zig
//! Manual signal coordination instead of automatic server integration.

const std = @import("std");
const httpx = @import("httpx");

fn onSignal(context: ?*anyopaque, event: httpx.signals.Event) void {
    const server: *httpx.Server = @ptrCast(@alignCast(context.?));

    // A second coalesced delivery means the operator asked twice: stop now.
    if (event.count >= 2) {
        server.stop();
    } else {
        server.requestShutdown();
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .signals = .{ .enabled = false },
    });
    defer server.deinit();

    // The server pointer is the subscription context; no wrapper type.
    var subscription = try httpx.signals.register(&server, onSignal, .{
        .interrupt = true,
        .terminate = true,
        .close = true,
        .logoff = true,
        .shutdown = true,
    });
    defer subscription.unregister();

    server.run();
    subscription.unregister();
}
```

## Why disable the integration?

Use this pattern when another component owns the process, when you need a custom
escalation policy, or when several libraries must share one subscription. The
callback runs on the manager's notification thread: keep it non-blocking and
call only `requestShutdown` / `stop`.

`unregister()` is idempotent and waits for any in-flight callback, so the
server can be destroyed immediately afterwards.

## How to Run

```bash
zig build example-manual-signals   # compile only
zig build run-manual-signals       # real process signals
```

Full source: `examples/manualSignals.zig`.

## Related

* [Guide: Signals & Graceful Shutdown](/guide/signals)
* [API: Signals](/api/signals)
* [Example: Custom Signals](/examples/custom-signals)
