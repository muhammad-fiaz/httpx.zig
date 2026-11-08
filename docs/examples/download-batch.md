# Example: Download Batch

Downloads multiple files concurrently with one shared client.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

const Job = struct {
    client: *httpx.Client,
    task: httpx.client.download.Task,

    fn run(ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        _ = try self.client.download(self.task.url, .{
            .path = self.task.dest,
            .progress = .disabled,
            .existing = .overwrite,
            .cancel = cancel,
            .createDirs = true,
        });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const sampleUrl = "https://httpbun.com/bytes/90";

    var jobs = [_]Job{
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file1.bin" } },
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file2.bin" } },
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file3.bin" } },
    };

    var pool = try httpx.concurrency.Pool.init(allocator, io, .{
        .workers = 3,
    });
    defer pool.deinit();

    for (&jobs) |*job| {
        try pool.submit(Job.run, job, null);
    }

    pool.shutdownDrain();
    pool.join();
}
```

## How to Run

```bash
zig build run-download-batch
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
