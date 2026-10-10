# HTTP/3 Client Runtime Example

End-to-end HTTP/3 with the high-level client runtime (`.http3 = true`).
See `examples/http3Client.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{
    .http3 = true,
});
defer client.deinit();

var response = try client.get(url, .{ .httpVersion = .http3 });
defer response.deinit();
std.debug.print("status={d}\n", .{response.status});
```

## Expected Output

```text
status=200
```

Status is 200 on success against the loopback HTTP/3 endpoint; URL/port vary per run.

## Run

```bash
zig build run-http3-client
```

## What to Verify

- Control-stream SETTINGS exchange validates.
- The client decodes HTTP/3 HEADERS/DATA frames into a standard `Response`.
