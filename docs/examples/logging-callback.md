# Logging Callback

HTTPX never prints on its own. Attach callbacks to receive structured
server and client events (slices are borrowed for the callback call only).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

// Server events: method, path, status, durationMs, bytesIn/bytesOut.
fn onServerEvent(event: httpx.ServerEvent) void {
    if (event.kind == .requestCompleted) {
        std.debug.print("[SRV] {s} {s} {d} {d}ms\n", .{
            event.method, event.path, event.status, event.durationMs,
        });
    }
}

// Client events: method, url (credentials redacted), status, durationMs.
fn onClientEvent(event: httpx.ClientEvent) void {
    if (event.kind == .requestCompleted) {
        std.debug.print("[CLI] {s} {s} {d}\n", .{
            event.method, event.url, event.status,
        });
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Attach to server (omit `.logging` entirely for fully silent operation).
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .logging = .{ .callback = onServerEvent, .level = .info },
    });
    defer server.deinit();

    // Attach to client.
    var client = httpx.Client.init(allocator, io, .{
        .eventCallback = onClientEvent,
    });
    defer client.deinit();
}
```

## Run

There is no single runnable file for this page; the pattern above is used
by server examples such as:

```bash
zig build run-custom-server
```

## Checklist

- [x] Server callback receives `requestCompleted` with method/path/status.
- [x] Client callback receives `requestCompleted` with method/url/status.
- [x] Omitting the callbacks keeps server and client fully silent.
- [x] Secrets (passwords, tokens, private keys) never appear in events.

### Level Filtering

Set `.level` (`.trace`, `.debug`, `.info`, `.warn`, `.err`, `.fatal`) to
drop events below a severity. Messages below the configured level are
silently dropped.
