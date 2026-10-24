# Concurrency API

The concurrency module provides a bounded worker pool and queue plus
parallel client helpers.

## Parallel Requests

`getAll` / `requestAll` on an initialized client execute multiple requests
and wait for all to complete:

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
(`src/concurrency/workerPool.zig`).

The pool borrows a Zig 0.17 `std.Io` value for blocking queue waits. Keep its
backing I/O context alive until the pool is joined and deinitialized. `submit`
blocks when the queue is full; `trySubmit` returns `QueueFull` or `QueueBusy`
immediately. `shutdownDrain` rejects new submissions, wakes waiters, and lets
queued tasks finish.

Task callbacks have the type `fn (?*anyopaque, *std.atomic.Value(bool)) anyerror!void`.
Successful callbacks increment `completed`; returned errors increment `failed`.
The pool records aggregate outcomes in `Stats` and does not retain individual
error values.

```zig
var pool = try httpx.WorkerPool.init(allocator, io, .{
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
used internally by the pool. Its initializer also takes the shared `std.Io`:
`try httpx.Queue.init(allocator, io, capacity)`.
