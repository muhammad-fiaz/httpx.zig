# Transfer Progress

Download progress with percentage, speed, ETA, and cancellation. See
`examples/downloadCustomProgress.zig`.

```zig
const Observer = struct {
    taskId: u32,

    fn onProgress(info: httpx.client.download.ProgressInfo, userData: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userData.?));
        const pct = if (info.percentage) |p| p else 0.0;
        std.debug.print("[Task {d}] {d:.1}% ({d} bytes) {d:.0} B/s ETA: {?d}s\n", .{
            self.taskId, pct, info.downloadedBytes, info.speedBps, info.etaSeconds,
        });
    }
};

var observer = Observer{ .taskId = 101 };
_ = try client.download(url, .{
    .path = "downloads/out.bin",
    .progress = .custom, // .auto / .enabled / .disabled / .quiet
    .onProgress = Observer.onProgress,
    .userData = &observer,
    .cancelFlag = &cancel, // *const std.atomic.Value(bool), optional
    .createDirs = true,
});
```

`ProgressInfo` carries `downloadedBytes`, `totalBytes`, `percentage`,
`speedBps`, `etaSeconds`, `elapsedMs`, `statusCode`, and `state`
(`starting`, `downloading`, `verifying`, `completed`, `failed`,
`cancelled`).

## Expected Output

```text
[Task 101] 100.0% (90 bytes) 12000 B/s ETA: 0s
```

Percentages, byte counts, speeds, and ETAs vary continuously during the transfer; task IDs reflect the observer setup. Requires network access to the download URL. See `examples/downloadCustomProgress.zig` (`run-download-custom-progress`).

## Run

```bash
zig build run-download-custom-progress
```

## What to Verify

- Progress callbacks fire with sane percentages and speeds.
- Cancellation via `cancelFlag` aborts the transfer.
