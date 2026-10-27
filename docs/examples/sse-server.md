# Example: Sse Server

Demonstrates sseServer.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .maxConnections = 5,
    });
    defer server.deinit();

    try server.get("/events", sseHandler);

    const port = server.localPort();
    std.debug.print("SSE server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;
    const urlEvents = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/events", .{port});
    var res = try client.get(urlEvents, .{});
    std.debug.print("GET /events -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("SSE server verification completed successfully.\n", .{});
}

fn sseHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.Event.Writer.init(ctx.allocator);
    try writer.writeEvent(&out, &[_][]const u8{"Connected to SSE live stream"}, "status", 1, 5000);
    try writer.writeEvent(&out, &[_][]const u8{"First data packet"}, "message", 2, null);

    return .{
        .status = 200,
        .body = out.items,
        .contentType = "text/event-stream; charset=utf-8",
        .headers = try ctx.allocator.dupe(httpx.router.Header, &[_]httpx.router.Header{
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Connection", .value = "keep-alive" },
        }),
    };
}
```

## Expected Output

```text
SSE server running on http://127.0.0.1:41237
GET /events -> status=200, body=retry:5000
id:1
event:status
data:Connected to SSE live stream

id:2
event:message
data:First data packet

SSE server verification completed successfully.
```

Statuses, event payloads, ids, retry intervals, URLs, and ports vary with the handler logic and the ephemeral port selected at runtime.

## How to Run

```bash
zig build run-sse-server
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
