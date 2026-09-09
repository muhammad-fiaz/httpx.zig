# HTTP/3 Server Runtime Example

HTTP/3 server routes with the high-level server runtime (`.http3 = true`).

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .http3 = true,
    .http2 = false,
});
defer server.deinit();

try server.get("/h3", h3Handler);

const thread = try server.start();
defer thread.join();
defer server.requestShutdown();
```

## Run

```bash
zig build run-http3-client
```

## What to Verify

- The server speaks HTTP/3 to capable clients.
- Routes dispatch identically across HTTP versions.
