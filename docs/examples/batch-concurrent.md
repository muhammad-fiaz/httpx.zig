# Batch Concurrent Requests

Run requests concurrently with `client.getAll(urls)` and
`client.requestAll(reqs)` (or the `httpx.getAll` / `httpx.requestAll`
zero-config helpers). See `examples/concurrent_demo.zig`.

```zig
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
var results = try client.getAll(urls);
defer {
    for (results) |*r| r.deinit();
    allocator.free(results);
}

const reqs = [_]httpx.RequestOptions{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
var batch = try client.requestAll(reqs);
defer {
    for (batch) |*r| r.deinit();
    allocator.free(batch);
}
```

Caller ownership: deinit each `Response`, then free the slice with the
client's allocator (`std.heap.page_allocator` for the global helpers).

## Run

```bash
zig build run-concurrent-demo
```

## What to Verify

- All parallel requests return 200.
- No leaks or double frees on batch error paths.
