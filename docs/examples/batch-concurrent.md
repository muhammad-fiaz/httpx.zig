# Batch Concurrent Requests

Run requests concurrently with `httpx.getAll(urls)` and
`httpx.requestAll(reqs)` (or the matching `client.getAll` /
`client.requestAll` methods on an explicit `Client`).
See `examples/concurrentDemo.zig`.

```zig
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
const results = httpx.getAll(urls) catch |err| {
    std.debug.print("getAll failed: {s}\n", .{@errorName(err)});
    return;
};
defer {
    for (results) |*r| r.deinit();
    std.heap.page_allocator.free(results);
}

const reqs = [_]httpx.RequestOptions{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
const batch = httpx.requestAll(reqs) catch |err| {
    std.debug.print("requestAll failed: {s}\n", .{@errorName(err)});
    return;
};
defer {
    for (batch) |*r| r.deinit();
    std.heap.page_allocator.free(batch);
}

for (results, 0..) |result, i| {
    std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, result.status, result.body.len });
}
```

Caller ownership: deinit each `Response`, then free the slice with
`std.heap.page_allocator` for the global helpers (or the client's
allocator for the `Client` methods).

## Expected Output

```text
Request 1: status=200 bodyLen=1234
Request 2: status=200 bodyLen=567
```

Status values reflect the live endpoints and body lengths vary per response.

## Run

```bash
zig build run-concurrent-demo
```

## What to Verify

- All parallel requests return 200.
- No leaks or double frees on batch error paths.
