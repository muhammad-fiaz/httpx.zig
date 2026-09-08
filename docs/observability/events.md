# Structured Lifecycle Events

HTTPX uses an event-driven observability model for both client requests and server connections. Instead of printing unconditionally to standard output, HTTPX emits structured event payloads to user-defined callback hooks.

## Overview

The zero-output default design guarantees that library internals never clutter console logs or disrupt terminal protocols. When observability is needed, attach an event handler at initialization time.

## Client Lifecycle Events

```zig
const std = @import("std");
const httpx = @import("httpx");

fn onClientEvent(event: httpx.client.ClientEvent) void {
    switch (event) {
        .request_start => |ev| {
            std.debug.print("[Client] Starting {s} {s}\n", .{ ev.method, ev.url });
        },
        .dns_resolved => |ev| {
            std.debug.print("[Client] DNS resolved {s} -> {s} in {d}ms\n", .{
                ev.host, ev.ip, ev.duration_ms,
            });
        },
        .tls_handshake_done => |ev| {
            std.debug.print("[Client] TLS 1.3 negotiated with {s} (cipher: {s})\n", .{
                ev.sni, ev.cipher,
            });
        },
        .response_received => |ev| {
            std.debug.print("[Client] Completed with status {d} in {d}ms\n", .{
                ev.status, ev.duration_ms,
            });
        },
        .request_failed => |ev| {
            std.debug.print("[Client] Request failed: {s}\n", .{@errorName(ev.err)});
        },
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .event_callback = &onClientEvent,
    });
    defer client.deinit();

    const res = try client.get("https://httpbin.org/get", .{});
    defer res.deinit();
}
```

---

## Server Lifecycle Events

On the server, events report connection acceptance, request routing, middleware timings, and worker thread status:

```zig
fn onServerEvent(event: httpx.server.ServerEvent) void {
    switch (event) {
        .connection_accepted => |ev| {
            std.debug.print("[Server] Accepted TCP from {s}\n", .{ev.remote_addr});
        },
        .request_routed => |ev| {
            std.debug.print("[Server] {s} {s} -> status {d} in {d}us\n", .{
                ev.method, ev.path, ev.status, ev.elapsed_us,
            });
        },
        .connection_closed => |ev| {
            std.debug.print("[Server] Closed connection from {s}\n", .{ev.remote_addr});
        },
    }
}
```

## Related

* [Observability: Logging](/observability/logging)
* [Observability: Metrics](/observability/metrics)
* [Example: Logging Callback](/examples/logging-callback)
