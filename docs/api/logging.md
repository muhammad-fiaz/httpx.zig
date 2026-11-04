# Logging API

Httpx.zig exposes structured logging types and callbacks. Logging is
application-controlled; the library does not write request events to an
implicit global destination.

## Public types

| Type | Purpose |
|---|---|
| `httpx.Logger` | Logger implementation |
| `httpx.LogLevel` | Event severity |
| `httpx.LogSink` | Destination abstraction |
| `httpx.LogRecord` | Structured log record |
| `httpx.LogField` | Structured field |
| `httpx.WriterSink` | Writer-backed sink |
| `httpx.ServerEvent` | Server lifecycle event |
| `httpx.ServerEventKind` | Server event category |

## Server callback

```zig
fn onEvent(event: httpx.logging.ServerEvent) void {
    if (event.kind == .requestCompleted) {
        std.debug.print("{s} {s} {d}\n", .{
            event.method,
            event.path,
            event.status,
        });
    }
}

var server = try httpx.Server.init(allocator, io, .{
    .logging = .{ .callback = onEvent },
});
defer server.deinit();
```

The callback receives structured events and decides how to format or route
them. Leave `.logging` at its default value to disable server event delivery.

## Related documentation

- [Logging guide](/observability/logging)
- [Events guide](/observability/events)
- [Server API](/api/server)
