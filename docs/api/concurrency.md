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

## Worker Pool

`httpx.concurrency.Pool` is a fixed-thread, bounded-queue pool with graceful
drain (`src/concurrency/workerPool.zig`). The same type is aliased as
`httpx.client.workerPool`.

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
var pool = try httpx.concurrency.Pool.init(allocator, io, .{
    .workers = 4,
    .queueCapacity = 1024,
    .autoStart = true,
});
defer pool.deinit();
```

### Configuration

The initializer takes `httpx.concurrency.workerPool.Config`:

```zig
pub const Config = struct {
    workers: u16 = 0, // 0 = auto (CPU count clamped 1..16)
    queueCapacity: u32 = 1024,
    autoStart: bool = true,
};
```

### Queue

`httpx.concurrency.Queue(T)` (`src/concurrency/queue.zig`) is the generic
thread-safe bounded queue used internally by the pool. Its initializer also
takes the shared `std.Io`:

```zig
var queue = try httpx.concurrency.Queue(u32).init(allocator, io, 1024);
defer queue.deinit();
try queue.push(42);
const value = try queue.pop();
```
