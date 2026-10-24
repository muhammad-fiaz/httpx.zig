# Batch Concurrent Requests

Run requests concurrently with `client.getAll(urls)` and
`client.requestAll(reqs)` on an initialized `Client`.
See `examples/concurrentDemo.zig`.

```zig
const urls = [_][]const u8{
    "https://httpbun.com/get",
    "https://httpbun.com/headers",
};
const results = client.getAll(urls) catch |err| {
    std.debug.print("getAll failed: {s}\n", .{@errorName(err)});
    return;
};
defer {
    for (results) |*r| r.deinit();
    std.heap.page_allocator.free(results);
}

const reqs = [_]httpx.client.RequestOptions{
    .{ .method = .GET, .url = "https://httpbun.com/get" },
    .{ .method = .GET, .url = "https://httpbun.com/headers" },
};
const batch = client.requestAll(reqs) catch |err| {
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

Caller ownership: deinit each `Response`, then free the slice with the
allocator passed to the client.

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
