# Streaming Guide

HTTPX supports incremental request uploads and incremental response reads on
the HTTP/1.1 client path, direct-to-disk downloads, and finite SSE responses.
The high-level `Response` is buffered up to `maxResponseSize`; use
`requestStream` when a response body must be consumed in chunks.

## Streaming Response Downloads

For large files, download directly to disk without loading the full payload
into RAM:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

_ = try client.download(
    "https://releases.example.com/large_archive.iso",
    .{ .path = "large_archive.iso" },
);
```

## Incremental Response Reads

`requestStream` returns a `ResponseStream` with a `read` method. On the
HTTP/1.1 transport the body is read from the socket as it arrives. HTTP/2 and
HTTP/3 upper layers currently buffer the completed response before returning
the stream.

```zig
var stream = try client.requestStream("https://example.com/export.csv", .{});
defer stream.deinit();

var buf: [16 * 1024]u8 = undefined;
while (true) {
    const n = try stream.read(&buf);
    if (n == 0) break;
    try processChunk(buf[0..n]);
}
```

For streaming uploads, set `RequestOptions.bodySource` to a `BodySource`; see
[Requests](/guide/requests#_4-streaming-uploads).

## Server-Sent Events (SSE)

`httpx.sse.Event.Writer` serializes SSE event blocks. Return the encoded body
with the `text/event-stream` content type:

```zig
fn eventsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.Event.Writer.init(ctx.allocator);
    try writer.writeEvent(&out, &.{"Server started"}, "status", 1, null);
    return .{
        .status = 200,
        .body = out.items,
        .contentType = "text/event-stream; charset=utf-8",
        .headers = &.{.{ .name = "Cache-Control", .value = "no-cache" }},
    };
}
```

The high-level server buffers each response body, so this form sends a finite
batch of events. Long-lived SSE connections require a custom HTTP/1.1
connection loop built from the socket and protocol primitives; the router
cannot keep a response open.

## Related

* [API: SSE](/api/sse)
* [Example: Streaming](/examples/streaming)
* [Example: Transfer Download](/examples/transfer-download)
