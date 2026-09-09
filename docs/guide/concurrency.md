# Concurrency & Async Tasks

`httpx.zig` provides explicit primitives for concurrent execution and
background task management: parallel client helpers plus a bounded worker
pool and queue.

## Parallel Requests

Execute multiple HTTP requests using `Client.getAll` / `Client.requestAll`
(or the `httpx.getAll` / `httpx.requestAll` zero-config helpers). They run
the requests and wait for all to complete:

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
```

For unreachable or slow hosts, set per-request `timeoutMs` so batch jobs
fail fast instead of waiting on default socket budgets:

```zig
var r = try client.get("https://slow.example.com", .{ .timeoutMs = 2_000 });
defer r.deinit();
```

## Worker Pool

`httpx.WorkerPool` (`src/concurrency/worker_pool.zig`) is a fixed-thread,
bounded-queue pool with graceful drain:

```zig
var pool = httpx.WorkerPool.init(allocator, .{
    .workers = 4,
    .queueCapacity = 1024,
    .autoStart = true,
});
defer pool.deinit();
```

### Defaults

- `workers = 0` means "choose a sensible default from the host CPU count"
  (clamped 1..16).
- `queueCapacity = 1024` bounds pending tasks before submission fails.
- `autoStart = true` starts worker threads on the first submitted task.

### Queue

`httpx.Queue` (`src/concurrency/queue.zig`) is the thread-safe bounded queue
used internally by the pool.

## Related

- [API: Concurrency](/api/concurrency)
- [Example: Concurrent Demo](/examples/concurrent-demo)
