# Concurrency API

The concurrency module provides a bounded worker pool and queue for
concurrent client operations and background tasks.

## Worker Pool & Concurrent Requests

`httpx.concurrency.Pool` is a fixed-thread, bounded-queue pool with graceful
drain (`src/concurrency/workerPool.zig`). The same type is aliased as
`httpx.client.workers`.

Execute multiple requests concurrently across worker threads:

```zig
const std = @import("std");
const httpx = @import("httpx");

const FetchTask = struct {
    url: []const u8,
    status: u16 = 0,

    fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const io = std.Io.Threaded.global_single_threaded.io();
        var client = httpx.Client.init(std.heap.smp_allocator, io, .{});
        defer client.deinit();

        var resp = try client.get(self.url, .{});
        defer resp.deinit();
        self.status = resp.status;
    }
};

var pool = try httpx.concurrency.Pool.init(allocator, io, .{
    .workers = 4,
    .queueCapacity = 1024,
});
defer pool.deinit();

var tasks = [_]FetchTask{
    .{ .url = "https://httpbun.com/get" },
    .{ .url = "https://httpbun.com/headers" },
};

for (&tasks) |*t| {
    try pool.submit(FetchTask.run, t, null);
}
pool.shutdownDrain();
pool.join();
```

The pool borrows a Zig 0.17 `std.Io` value for blocking queue waits. Keep its
backing I/O context alive until the pool is joined and deinitialized. `submit`
blocks when the queue is full; `trySubmit` returns `QueueFull` or `QueueBusy`
immediately. `shutdownDrain` rejects new submissions, wakes waiters, and lets
queued tasks finish.

Task callbacks have the type `fn (?*anyopaque, *std.atomic.Value(bool)) anyerror!void`.
Successful callbacks increment `completed`; returned errors increment `failed`.
The pool records aggregate outcomes in `Stats` and does not retain individual
error values.
