# Streaming

Send data in chunks for progressive response delivery.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn stream(ctx: *httpx.Context) anyerror!httpx.Response {
    var trailers = httpx.Headers.init(ctx.allocator);
    defer trailers.deinit();

    try trailers.set("X-Stream-End", "ok");
    return ctx.chunked("part-1\npart-2\npart-3\n", &trailers);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/stream", stream);
    try server.listen();
}
```

## Run

```bash
zig build run-streaming
```

## What to Verify

- Response uses `Transfer-Encoding: chunked`.
- Trailer header is present after final chunk.
