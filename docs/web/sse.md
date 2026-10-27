# Server-Sent Events (SSE)

HTTPX implements the WHATWG Server-Sent Events format: `httpx.sse.Event.Writer`
serializes event blocks, and `httpx.sse.Event.Parser` parses an inbound
`text/event-stream` body.

## Server SSE Handler

The high-level server buffers each response body, so a route can return a
finite batch of events in one response:

```zig
const std = @import("std");
const httpx = @import("httpx");

fn liveFeedHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.Event.Writer.init(ctx.allocator);
    try writer.writeEvent(&out, &.{"Client connected to live feed"}, "connected", 0, null);

    var count: u32 = 1;
    while (count <= 10) : (count += 1) {
        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Heartbeat count: {d}", .{count});
        try writer.writeEvent(&out, &.{msg}, "tick", count, null);
    }

    return .{
        .status = 200,
        .body = out.items,
        .contentType = "text/event-stream; charset=utf-8",
        .headers = &.{.{ .name = "Cache-Control", .value = "no-cache" }},
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();
    try server.get("/api/live-feed", liveFeedHandler);
    server.run();
}
```

Long-lived SSE connections require a custom HTTP/1.1 connection loop built
from the socket and protocol primitives; the router cannot keep a response
open.

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
