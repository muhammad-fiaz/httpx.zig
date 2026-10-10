# HTTP/2 Client Runtime Example

End-to-end HTTP/2 over cleartext (h2c) with the high-level client runtime
(`.http2 = true`). See `examples/http2Client.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{
    .http2 = true,
});
defer client.deinit();

var response = try client.get(url, .{ .httpVersion = .http2 });
defer response.deinit();
std.debug.print("status={d}\n", .{response.status});
```

## Expected Output

```text
status=200
```

Status is 200 on success against the loopback h2c server; URL/port vary per run.

## Run

```bash
zig build run-http2-client
```

## What to Verify

- The local loopback server receives an HTTP/2 preface, SETTINGS, HEADERS, and DATA flow.
- The client decodes HTTP/2 response headers/body into a standard `Response`.
