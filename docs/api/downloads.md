# Downloads API

`client.download` streams remote files directly to disk with resumable transfers,
in-flight cryptographic hashing, and progress reporting.

## Download Types

| Type | Purpose |
|---|---|
| `httpx.client.download.Result` | Metrics and outcome of a completed download |
| `httpx.client.download.Task` | Task descriptor (`url`, `dest`) |
| `httpx.client.download.Error` | Download failure modes |
| `httpx.client.download.FileInfo` | Remote file metadata |
| `httpx.client.download.parseChecksumFile` | Parse a checksum manifest into an expected hash |
| `httpx.client.download.verifyFile` | Verify a local file against checksum options |

## Single and Concurrent Downloads

For single downloads, call `client.download(url, .{ ... })`:

```zig
const result = try client.download("https://example.com/archive.tar.gz", .{
    .path = "downloads/archive.tar.gz",
    .existing = .resumePartial,
    .progress = .enabled,
});
```

For concurrent multi-file downloads, use `httpx.concurrency.Pool` with one
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
            .cancel = cancel,
        });
    }
};

var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
defer pool.deinit();

var jobs = [_]Job{
    .{ .client = &client, .task = .{ .url = "https://example.com/a.tar", .dest = "a.tar" } },
    .{ .client = &client, .task = .{ .url = "https://example.com/b.tar", .dest = "b.tar" } },
};

for (&jobs) |*job| {
    try pool.submit(Job.run, job, null);
}
pool.shutdownDrain();
pool.join();
```

See [download examples](/examples/download) for complete workflows.
