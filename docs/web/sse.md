# Server-Sent Events (SSE)

HTTPX implements the W3C Server-Sent Events (SSE) specification, enabling persistent, unidirectional event streams from server to browser over standard HTTP/1.1 or HTTP/2.

## Server SSE Handler

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    server.sse("/api/live-feed", struct {
        fn handle(stream: *httpx.sse.Writer) !void {
            try stream.send(.{
                .event = "connected",
                .data = "Client connected to live feed",
            });

            var count: u32 = 0;
            while (count < 10) : (count += 1) {
                std.time.sleep(1 * std.time.ns_per_s);
                var buf: [64]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Heartbeat count: {d}", .{count});
                try stream.send(.{
                    .id = count,
                    .event = "tick",
                    .data = msg,
                });
            }
        }
    }.handle);

    try server.run();
}
```

## Wire Format

SSE transmits text streams with `Content-Type: text/event-stream; charset=utf-8`:
```text
id: 1
event: tick
data: Heartbeat count: 0

id: 2
event: tick
data: Heartbeat count: 1
```

## Related

* [API: SSE](/api/sse)
* [Example: SSE Server](/examples/sse-server)
