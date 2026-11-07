# Concurrency & Async Tasks

`httpx.zig` provides explicit primitives for concurrent execution and
background task management using `httpx.concurrency.Pool`.

## Concurrent Requests with Worker Pool

Execute multiple HTTP requests concurrently using `httpx.concurrency.Pool`
with an initialized client:

```zig
const std = @import("std");
const httpx = @import("httpx");

const FetchTask = struct {
    url: []const u8,
    status: u16 = 0,
    bodyLen: usize = 0,

    fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const t_io = std.Io.Threaded.global_single_threaded.io();
        var client = httpx.Client.init(std.heap.smp_allocator, t_io, .{});
        defer client.deinit();

        var resp = try client.get(self.url, .{});
        defer resp.deinit();
        self.status = resp.status;
        self.bodyLen = resp.body.len;
    }
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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
}
```

For unreachable or slow hosts, set per-request `timeoutMs` so worker tasks
fail fast instead of waiting on default socket budgets:

```zig
var r = try client.get("https://slow.example.com", .{ .timeoutMs = 2_000 });
defer r.deinit();
```

## Worker Pool

`httpx.concurrency.Pool` (`src/concurrency/workerPool.zig`) is a fixed-thread,
bounded-queue pool with graceful drain:

Pass a live Zig 0.17 `std.Io` to the pool. It backs blocking queue waits and
must outlive the pool. `submit` applies backpressure when the queue is full;
`trySubmit` fails immediately with `QueueFull` or `QueueBusy`.

```zig
var pool = try httpx.concurrency.Pool.init(allocator, io, .{
    .workers = 4,
    .queueCapacity = 1024,
    .autoStart = true,
});
defer pool.deinit();
```
