# SSE API

Server-Sent Events parsing and streaming (`src/web/sse/`).

## Parser (`httpx.sse.Parser`)

| Member | Description |
|--------|-------------|
| `Event` | Parsed event: `eventType`, `data`, `id`, `retryMs` |
| `EventParser` | Stateful WHATWG stream parser |

```zig
var parser = httpx.sse.Parser.EventParser.init(allocator);
defer parser.deinit();
// feed chunks, drain parser.next() for Event values
```

## Writer (`httpx.sse.Writer`)

`httpx.sse.Writer.EventWriter` builds SSE payloads in handlers:

```zig
var out = std.ArrayList(u8).empty;
var writer = httpx.sse.Writer.EventWriter.init(ctx.allocator);
try writer.writeEvent(&out, &[_][]const u8{"payload"}, "message", 1, null);
return .{ .status = 200, .body = out.items, .contentType = "text/event-stream; charset=utf-8" };
```

See `examples/sse_server.zig`.
