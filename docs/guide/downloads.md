# File Downloads

HTTPX provides production-grade file downloads with streaming directly to disk,
automatic resume, progress tracking, and checksum verification.

## Downloading a File

Use `client.download(url, options)` with standard `.{}` options:

```zig
const res = try client.download("https://example.com/file.zip", .{
    .path = "downloads/file.zip",
    .progress = .enabled,
    .existing = .resumePartial,
    .verify = .{
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    },
});
std.debug.print("Downloaded {d} bytes to {s}\n", .{ res.downloadedBytes, res.destinationPath() });
```

## Downloading Multiple Files

Run concurrent downloads cleanly using `httpx.concurrency.Pool` with `client.download`:

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
            .existing = .overwrite,
            .cancelFlag = cancel,
            .createDirs = true,
        });
    }
};

var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
defer pool.deinit();

var tasks = [_]DownloadTask{
    .{ .url = "https://example.com/a.tar", .dest = "downloads/a.tar" },
    .{ .url = "https://example.com/b.tar", .dest = "downloads/b.tar" },
};

for (&tasks) |*t| {
    try pool.submit(DownloadTask.run, t, null);
}
pool.shutdownDrain();
pool.join();
```

## Important Options

| Option | Type | Default | Purpose |
|---|---|---:|---|
| `path` | `[]const u8` | `""` | Destination path or directory |
| `existing` | `ExistingFilePolicy` | `.overwrite` | Behavior when the destination exists |
| `progress` | `ProgressMode` | `.auto` | Progress reporting mode |
| `atomic` | `bool` | `true` | Download to a temporary file before replacement |
| `createDirs` | `bool` | `true` | Create missing parent directories |
| `maxRetries` | `u32` | `3` | Retry attempts |
| `timeoutMs` | `?u64` | `null` | Per-download timeout |
| `verify` | `VerifyOptions` | `.{}` | Checksum and size verification |
