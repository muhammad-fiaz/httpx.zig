# Structured Lifecycle Events

HTTPX uses an event-driven observability model for client requests and server
connections. Instead of printing unconditionally to standard output, HTTPX
delivers structured event payloads to user-defined callback hooks.

## Overview

The zero-output default design guarantees that library internals never clutter
console logs or disrupt terminal protocols. When observability is needed,
attach an event handler at initialization time.

## Client Request Events

```zig
const std = @import("std");
const httpx = @import("httpx");

fn onClientEvent(event: httpx.logging.ClientEvent) void {
    switch (event.kind) {
        .requestCompleted => std.debug.print("[Client] {s} {s} -> {d}\n", .{
            event.method, event.url, event.status,
        }),
        .requestFailed => std.debug.print("[Client] {s} {s} failed: {s}\n", .{
            event.method, event.url, event.message,
        }),
        else => {},
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .eventCallback = &onClientEvent,
    });
    defer client.deinit();

    var res = try client.get("https://httpbun.com/get", .{});
    defer res.deinit();
}
```

The client callback currently emits `requestCompleted` with the method, URL,
and response status, or `requestFailed` with the method, URL, and error name.
`ClientEventKind` also defines `requestStarted`, `redirect`, `retry`,
`dnsLookup`, `dnsCacheHit`, `connectionEstablished`, `connectionReused`,
`tlsHandshake`, `timeout`, and `cancellation`, but the high-level client does
not currently emit those kinds.

Event slices are borrowed for the callback duration only. Copy any value you
need to retain.

## Server Request Events

```zig
fn onServerEvent(event: httpx.logging.ServerEvent) void {
    switch (event.kind) {
        .serverStarted => std.debug.print("[Server] listening\n", .{}),
        .requestCompleted => std.debug.print("[Server] {s} {s} -> {d} in {d}ms\n", .{
            event.method, event.path, event.status, event.durationMs,
        }),
        .tlsHandshakeFailed => std.debug.print("[Server] TLS failure: {s}\n", .{
            event.message,
        }),
        .serverStopped => std.debug.print("[Server] stopped\n", .{}),
        else => {},
    }
}
```

The server callback currently emits `serverStarted`, `serverStopped`,
`requestCompleted`, and `tlsHandshakeFailed`. `ServerEventKind` also defines
connection, routing, middleware, handler, and worker kinds for applications
that need to extend instrumentation, but the high-level server does not emit
them today.

Pass `.logging = .{ .callback = &onServerEvent }` in the options passed to
`httpx.Server.init`. The `.logging.level` field filters events below the
configured severity.

## Related

* [Observability: Logging](/observability/logging)
* [Observability: Metrics](/observability/metrics)
* [Example: Logging Callback](/examples/logging-callback)
