# Concurrency API

The concurrency module provides a bounded worker pool and queue plus
parallel client helpers.

## Parallel Requests

`Client.getAll` / `Client.requestAll` (and the `httpx.getAll` /
`httpx.requestAll` zero-config helpers) execute multiple requests and wait
for all to complete:

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

## WorkerPool

A fixed-thread, bounded-queue pool with graceful drain
(`src/concurrency/worker_pool.zig`).

```zig
var pool = httpx.WorkerPool.init(allocator, .{
    .workers = 4,
    .queueCapacity = 1024,
    .autoStart = true,
});
defer pool.deinit();
```

### Configuration (`WorkerPoolConfig`)

```zig
pub const Config = struct {
    workers: u16 = 0, // 0 = auto (CPU count clamped 1..16)
    queueCapacity: u32 = 1024,
    autoStart: bool = true,
};
```

### Queue

`httpx.Queue` (`src/concurrency/queue.zig`) is a thread-safe bounded queue
used internally by the pool.
