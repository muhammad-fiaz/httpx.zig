# Downloads API

`client.download` streams remote files directly to disk with resumable transfers,
in-flight cryptographic hashing, and progress reporting.

## Download Types

| Type | Purpose |
|---|---|
| `httpx.client.Downloader` | Download engine bound to client and allocator |
| `httpx.client.DownloadResult` | Metrics and outcome of a completed download |
| `httpx.client.DownloadTask` | Task descriptor (`url`, `dest`) |
| `httpx.client.DownloadError` | Download failure modes |
| `httpx.client.RemoteFileInfo` | Remote file metadata |

## Single and Concurrent Downloads

For single downloads, call `client.download(url, .{ ... })`:

```zig
const result = try client.download("https://example.com/archive.tar.gz", .{
    .path = "downloads/archive.tar.gz",
    .existing = .resumePartial,
    .progress = .enabled,
});
```

For concurrent multi-file downloads, use `httpx.concurrency.Pool` with `client.download`:

```zig
const std = @import("std");
const httpx = @import("httpx");

const DownloadTask = struct {
    url: []const u8,
    dest: []const u8,

    fn run(ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const io = std.Io.Threaded.global_single_threaded.io();
        var client = httpx.Client.init(std.heap.smp_allocator, io, .{});
        defer client.deinit();

        _ = try client.download(self.url, .{
            .path = self.dest,
            .progress = .enabled,
            .cancel = cancel,
        });
    }
};

var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
defer pool.deinit();

var tasks = [_]DownloadTask{
    .{ .url = "https://example.com/a.tar", .dest = "a.tar" },
    .{ .url = "https://example.com/b.tar", .dest = "b.tar" },
};

for (&tasks) |*t| {
    try pool.submit(DownloadTask.run, t, null);
}
pool.shutdownDrain();
pool.join();
```

See [download examples](/examples/download) for complete workflows.
