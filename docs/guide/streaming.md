# Streaming Guide

HTTPX supports full duplex HTTP streaming, including chunked request and response bodies, Server-Sent Events (SSE), and large file transfers.

## Streaming Response Downloads

For multi-gigabyte files, download directly to disk or process body bytes in streaming chunks without loading the full payload into RAM:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

// Stream download directly to local destination file
try client.download(
    "https://releases.example.com/large_archive.iso",
    "large_archive.iso",
    .{},
);
```

---

## Server-Sent Events (SSE)

Stream real-time server events to web browsers using standard SSE:

```zig
server.sse("/events", struct {
    fn handle(stream: *httpx.sse.Writer) !void {
        try stream.send(.{
            .event = "status",
            .data = "Server started",
        });

        var tick: usize = 0;
        while (tick < 5) : (tick += 1) {
            std.time.sleep(1 * std.time.ns_per_s);
            try stream.send(.{
                .event = "heartbeat",
                .data = "ping",
            });
        }
    }
}.handle);
```

## Related

* [API: SSE](/api/sse)
* [Example: Streaming](/examples/streaming)
* [Example: Transfer Download](/examples/transfer-download)
