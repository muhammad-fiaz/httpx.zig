# Distributed Tracing

HTTPX supports distributed tracing using W3C Trace Context (`traceparent` and `tracestate`) headers, enabling end-to-end request correlation across microservices.

## W3C Trace Context Header Format

The `traceparent` header follows the 4-part hex-encoded specification:
```text
version - trace_id (16 bytes hex) - parent_id (8 bytes hex) - trace_flags (1 byte hex)
00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

## Propagating Traces in Client Requests

```zig
const trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
const span_id = "00f067aa0ba902b7";
var trace_hdr_buf: [128]u8 = undefined;
const trace_hdr = try std.fmt.bufPrint(&trace_hdr_buf, "00-{s}-{s}-01", .{ trace_id, span_id });

const resp = try client.get("https://backend.service/api/query", .{
    .headers = &.{
        .{ .name = "traceparent", .value = trace_hdr },
    },
});
defer resp.deinit();
```

## Server Trace Extractor Middleware

```zig
fn traceMiddleware(ctx: *httpx.Context) !void {
    if (ctx.header("traceparent")) |traceparent| {
        // Store trace ID in context local state for subsequent logs and queries
        ctx.set("traceparent", traceparent);
    }
    try ctx.next();
}
```

## Related

* [Observability: Logging](/observability/logging)
* [Observability: Events](/observability/events)
