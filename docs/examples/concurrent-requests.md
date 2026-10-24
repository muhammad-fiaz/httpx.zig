# Concurrent Requests

Execute multiple requests in parallel with an initialized client's
`getAll` / `requestAll` methods.
See `examples/concurrentDemo.zig` and [Batch Concurrent](/examples/batch-concurrent).

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
    allocator.free(results);
}

for (results, 0..) |result, i| {
    std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, result.status, result.body.len });
}
```

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
- Batch error paths clean up without double frees.
