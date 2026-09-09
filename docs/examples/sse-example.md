# Server-Sent Events (SSE) Example

SSE payloads with `httpx.sse.EventWriter`, parsed back with
`httpx.sse.EventParser`. See `examples/sse_server.zig`.

```zig
fn sseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.EventWriter.init(ctx.allocator);
    try writer.writeEvent(&out, &[_][]const u8{"Hello, SSE!"}, "message", 1, null);
    return .{
        .status = 200,
        .body = out.items,
        .contentType = "text/event-stream; charset=utf-8",
    };
}
```

Parsed events carry `eventType`, `data`, `id`, and `retryMs`.

## Run

```bash
zig build run-sse-server
```

## Checklist

- [x] SSE events use W3C wire format (`event:`, `id:`, `data:`)
- [x] Server returns `Content-Type: text/event-stream`
- [x] Client receives all events in order
