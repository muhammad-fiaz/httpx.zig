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

## Expected Output

```text
=== HTTP/3 live loopback (QUIC + TLS 1.3 over UDP) ===
5. LIVE client.get: status=200 version=http3 body={"path":"/api/v1/resource","protocol":"HTTP/3"}
H3 LIVE DEMO VERIFICATION PASSED
```

Status is 200 on success; port, stream IDs, and body path vary by route. See `examples/http3Client.zig` for the full loopback demo.

## Run

```bash
zig build run-http3-client
```

## What to Verify

- The server speaks HTTP/3 to capable clients.
- Routes dispatch identically across HTTP versions.
