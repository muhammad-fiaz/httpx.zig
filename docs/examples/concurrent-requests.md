# Concurrent Requests

Execute multiple requests in parallel with `getAll` / `requestAll`.
See `examples/concurrent_demo.zig` and [Batch Concurrent](/examples/batch-concurrent).

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
var results = try client.getAll(urls);
defer {
    for (results) |*r| r.deinit();
    allocator.free(results);
}
```

## Run

```bash
zig build run-concurrent-demo
```

## What to Verify

- All parallel requests return 200.
- Batch error paths clean up without double frees.
