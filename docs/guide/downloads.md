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

Run concurrent downloads cleanly using `httpx.concurrency.Pool` with one
shared `client.download` call per task. The client pool, DNS cache, and TLS
session cache are internally synchronized, so sharing one client is safe:

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

var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
defer pool.deinit();

var jobs = [_]Job{
    .{ .client = &client, .task = .{ .url = "https://example.com/a.tar", .dest = "downloads/a.tar" } },
    .{ .client = &client, .task = .{ .url = "https://example.com/b.tar", .dest = "downloads/b.tar" } },
};

for (&jobs) |*job| {
    try pool.submit(Job.run, job, null);
}
pool.shutdownDrain();
pool.join();
```

## Important Options

| Option | Type | Default | Purpose |
|---|---|---:|---|
| `path` | `[]const u8` | `""` | Destination path or directory |
| `existing` | `Existing` | `.overwrite` | Behavior when the destination exists |
| `progress` | `Progress` | `.auto` | Progress reporting mode |
| `atomic` | `bool` | `true` | Download to a temporary file before replacement |
| `createDirs` | `bool` | `true` | Create missing parent directories |
| `maxRetries` | `u32` | `3` | Retry attempts |
| `timeoutMs` | `?u64` | `null` | Per-download timeout |
| `verify` | `VerifyOptions` | `.{}` | Checksum and size verification |
