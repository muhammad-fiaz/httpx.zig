# Server-Sent Events (SSE) Example

SSE payloads with `httpx.sse.Writer`, parsed back with
`httpx.sse.Parser`. See `examples/sseServer.zig`.

```zig
fn sseHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var writer = httpx.sse.Writer.init(ctx.allocator, ctx.io, .{});
    defer writer.deinit();
    try writer.writeEvent(&.{"Connected to SSE live stream"}, .{ .event = "status", .id = 1, .retryMs = 5000 });
    try writer.writeEvent(&.{"First data packet"}, .{ .event = "message", .id = 2 });
    return .{
        .status = 200,
        .body = writer.buffered(),
        .contentType = "text/event-stream; charset=utf-8",
    };
}
```

Parsed events carry `eventType`, `data`, `id`, and `retryMs`.

## Expected Output

The handler produces SSE wire-format body text; a client `GET /events`
(comparing `examples/sseServer.zig`) prints lines in this format
(representative values shown):

```text
GET /events -> status=200, body=retry:5000
id:1
event:status
data:Connected to SSE live stream

id:2
event:message
data:First data packet

```

Statuses, event payloads, ids, retry intervals, URLs, and ports vary with the handler logic and the ephemeral port selected at runtime.

## Run

```bash
zig build run-sse-server
```
