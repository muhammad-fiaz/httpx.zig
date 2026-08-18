# SSE API

Server-Sent Events client parsing and streaming.

Located in `src/util/sse.zig`.

## SseEvent

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `data` | `[]const u8` | (required) | Event payload body |
| `event` | `?[]const u8` | `null` | Optional SSE event name |
| `id` | `?[]const u8` | `null` | Optional event id |
| `retry_ms` | `?u32` | `null` | Optional client reconnect hint |

### Event.format(allocator)

Serializes an SSE event to wire format. Caller owns the returned slice.

## SseWriter(WriterType)

Streaming SSE writer that emits events to any writer interface. Useful for server-side SSE endpoints that push events over a connection.

| Method | Description |
|--------|-------------|
| `init(underlying)` | Create a writer wrapping the given underlying writer |
| `sendEvent(event)` | Send a complete SSE event (id, event, retry, data) |
| `sendComment(comment)` | Send a comment line (used as keep-alive) |
| `sendNamed(name, data)` | Send a named event with data |
| `sendData(data)` | Send a plain data event (no event name) |
| `sendWithId(data, id)` | Send an event with an ID for Last-Event-ID tracking |

Fields:
- `last_event_id: ?[]const u8` — tracks the last event ID sent

## parseSseStream(allocator, data, on_event)

Parses a raw SSE stream, invoking the callback for each complete event. Returns the number of events parsed.

```zig
fn onEvent(event: SseEvent) void {
    std.debug.print("event: {s}\n", .{event.data});
}
const count = httpx.parseSseStream(allocator, raw_data, onEvent);
```

Root-level alias: `httpx.parseSseStream(...)`, `httpx.SseEvent`.
