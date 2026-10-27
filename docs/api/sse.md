# SSE API

Server-Sent Events writers and parsers live in `src/web/sse/`.

## Event

`httpx.sse.Event` contains the parsed event fields:

| Field | Type | Description |
|-------|------|-------------|
| `eventType` | `[]const u8` | Event name; defaults to `"message"` |
| `data` | `[]const u8` | Event payload, with multiple data lines joined by `\n` |
| `id` | `?[]const u8` | Event identifier, when supplied |
| `retryMs` | `?u32` | Reconnection delay in milliseconds |

## Writer

`httpx.sse.Event.Writer` serializes event blocks for a `text/event-stream`
response:

```zig
var out = std.ArrayList(u8).empty;
var writer = httpx.sse.Event.Writer.init(ctx.allocator);
try writer.writeEvent(&out, &.{"payload"}, "message", 1, null);
return .{
    .status = 200,
    .body = out.items,
    .contentType = "text/event-stream; charset=utf-8",
};
```

`writeEvent` accepts data lines, an optional event name, an optional event ID,
and an optional retry delay. `writeComment` emits a comment frame for
keep-alives.

## Parser

`httpx.sse.Event.Parser` is a stateful WHATWG stream parser:

```zig
var parser = httpx.sse.Event.Parser.init(allocator);
defer parser.deinit();

if (try parser.processLine("data: hello\n")) |event| {
    // event.data is valid until the next parser call or deinit.
}
```

Use `feed` to process a chunk and receive every completed event:

```zig
fn onEvent(context: *Context, event: httpx.sse.Event) void {
    _ = context;
    _ = event;
}

try parser.feed(chunk, &context, onEvent);
```

`parseAll` parses an in-memory stream and returns owned events. Release the
result with `freeEvents`.
