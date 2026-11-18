# Concurrent Requests

Execute multiple requests concurrently using `httpx.concurrency.Pool`.
See `examples/concurrentDemo.zig` and [Batch Concurrent](/examples/batch-concurrent).

```zig
const std = @import("std");
const httpx = @import("httpx");

const FetchTask = struct {
    url: []const u8,
    status: u16 = 0,
    bodyLen: usize = 0,

    fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const io = std.Io.Threaded.global_single_threaded.io();
        var client = httpx.Client.init(std.heap.smp_allocator, io, .{});
        defer client.deinit();

        var resp = try client.get(self.url, .{});
        defer resp.deinit();
        self.status = resp.status;
        self.bodyLen = resp.body.len;
    }
};

var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
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

for (tasks, 0..) |t, i| {
    std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, t.status, t.bodyLen });
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
