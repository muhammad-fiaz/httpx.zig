# HTTP/2 Server Runtime Example

End-to-end HTTP/2 server routes with the high-level server runtime
(`.http2 = true`). See `examples/http11Server.zig` for the HTTP/1.x shape
and `examples/http2Client.zig` for h2c verification.

```zig
var server = try httpx.server.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .http2 = true,
});
defer server.deinit();

try server.get("/h2", h2Handler);

const thread = try server.start();
defer thread.join();
defer server.requestShutdown();
```

## Expected Output

```text
HTTP/2 Server received: GET /h2
HTTP/2 response status: 200
body: {"status":200,"protocol":"HTTP/2","message":"Hello from HTTP/2"}
```

Method/path reflect the demo route; status is 200 on success.

## Run

```bash
zig build run-http2-client
```

## What to Verify

- The server speaks HTTP/2 (preface + SETTINGS) to h2c clients.
- Routes dispatch identically across HTTP versions.
