# Structured Lifecycle Events

HTTPX uses an event-driven observability model for both client requests and server connections. Instead of printing unconditionally to standard output, HTTPX emits structured event payloads to user-defined callback hooks.

## Overview

The zero-output default design guarantees that library internals never clutter console logs or disrupt terminal protocols. When observability is needed, attach an event handler at initialization time.

## Client Lifecycle Events

```zig
const std = @import("std");
const httpx = @import("httpx");

fn onClientEvent(event: httpx.ClientEvent) void {
    switch (event.kind) {
        .requestStarted => std.debug.print("[Client] Starting {s} {s}\n", .{ event.method, event.url }),
        .dnsLookup => std.debug.print("[Client] DNS lookup for {s}\n", .{event.url}),
        .tlsHandshake => std.debug.print("[Client] TLS handshake done in {d}ms\n", .{event.durationMs}),
        .requestCompleted => std.debug.print("[Client] Completed with status {d} in {d}ms\n", .{
            event.status, event.durationMs,
        }),
        .requestFailed => std.debug.print("[Client] Request failed: {s}\n", .{event.message}),
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

    const res = try client.get("https://httpbin.org/get", .{});
    defer res.deinit();
}
```

Client event kinds: `requestStarted`, `requestCompleted`, `requestFailed`,
`redirect`, `retry`, `dnsLookup`, `dnsCacheHit`, `connectionEstablished`,
`connectionReused`, `tlsHandshake`, `timeout`, `cancellation`.
Payload fields: `method`, `url`, `status`, `durationMs`, `bytesSent`,
`bytesReceived`, `message` (all borrowed for the callback duration only).

---

## Server Lifecycle Events

On the server, events report connection acceptance, request routing, middleware timings, and worker thread status:

```zig
fn onServerEvent(event: httpx.ServerEvent) void {
    switch (event.kind) {
        .connectionAccepted => std.debug.print("[Server] Accepted connection\n", .{}),
        .requestCompleted => std.debug.print("[Server] {s} {s} -> status {d} in {d}ms\n", .{
            event.method, event.path, event.status, event.durationMs,
        }),
        .connectionClosed => std.debug.print("[Server] Closed connection\n", .{}),
        else => {},
    }
}
```

Server event kinds: `serverStarted`, `serverStopped`, `connectionAccepted`,
`connectionClosed`, `requestReceived`, `requestCompleted`, `requestFailed`,
`handlerError`, `middlewareError`, `workerStarted`, `workerStopped`,
`routeNotFound`, `methodNotAllowed`, `tlsHandshakeFailed`.
Payload fields: `method`, `path`, `status`, `durationMs`, `bytesIn`,
`bytesOut`, `message` (all borrowed for the callback duration only).

Attach with `ServerConfig.logging = .{ .callback = &onServerEvent }`.

## Related

* [Observability: Logging](/observability/logging)
* [Observability: Metrics](/observability/metrics)
* [Example: Logging Callback](/examples/logging-callback)
