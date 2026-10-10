# Server-Sent Events (SSE) Example

SSE payloads with `httpx.sse.EventWriter`, parsed back with
`httpx.sse.EventParser`. See `examples/sseServer.zig`.

```zig
fn sseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.Writer.EventWriter.init(ctx.allocator);
    try writer.writeEvent(&out, &[_][]const u8{"Connected to SSE live stream"}, "status", 1, 5000);
    try writer.writeEvent(&out, &[_][]const u8{"First data packet"}, "message", 2, null);
    return .{
        .status = 200,
        .body = out.items,
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

## Checklist

- [x] SSE events use W3C wire format (`event:`, `id:`, `data:`)
- [x] Server returns `Content-Type: text/event-stream`
- [x] Client receives all events in order
