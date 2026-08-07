# Server-Sent Events (SSE) Example

Demonstrates SSE event formatting and streaming from server to client. Uses `httpx.sse.Event` for W3C-compliant SSE wire format and `Context.sse()` for server-side SSE responses.

## Demo Program

```zig
// Format an SSE event (W3C wire format)
const event = httpx.sse.Event{
    .event = "message",
    .id = "1",
    .data = "Hello, World!",
};
const formatted = try event.format(allocator);

// Server handler returning SSE response
fn sseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const events = [_]httpx.SseEvent{
        .{ .event = "message", .id = "1", .data = "Hello, SSE!" },
        .{ .event = "update", .id = "2", .data = "Second event" },
    };
    return ctx.sse(&events);
}
```

## Run

```
zig build example-sse-example
```

## Checklist

- [x] SSE events are formatted in W3C wire format (`event:`, `id:`, `data:`)
- [x] Multi-line data is split correctly
- [x] Retry events include `retry:` field
- [x] Server returns proper `Content-Type: text/event-stream`
- [x] Client receives all events in order
