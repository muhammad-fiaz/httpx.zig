# Example: Download Custom Progress

Demonstrates downloadCustomProgress.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

const DownloadObserver = struct {
    taskId: u32,

    fn onProgress(info: httpx.client.download.ProgressInfo, userData: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userData.?));
        const pct = if (info.percentage) |p| p else 0.0;
        const stateColor: []const u8 = switch (info.state) {
            .completed => "\x1b[32m",
            .downloading => "\x1b[36m",
            .verifying => "\x1b[35m",
            .failed => "\x1b[31m",
            .cancelled => "\x1b[33m",
            .starting => "\x1b[34m",
        };
        const reset = "\x1b[0m";

        std.debug.print("[Observer Task {d}] State: {s}{s}{s} | Progress: {d:.1}% ({d} bytes) | Speed: {d:.2} KB/s | ETA: {?d}s\n", .{
            self.taskId,
            stateColor,
            @tagName(info.state),
            reset,
            pct,
            info.downloadedBytes,
            info.speedBps / 1024.0,
            info.etaSeconds,
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

    var observer = DownloadObserver{
        .taskId = 101,
    };

    // 1. Successful download test
    const sampleUrl = "https://httpbun.com/bytes/90";
    std.debug.print("==> Downloading {s} with custom progress callback observer...\n", .{sampleUrl});

    _ = client.download(
        sampleUrl,
        .{
            .path = "downloads/observed_download.bin",
            .progress = .custom,
            .onProgress = DownloadObserver.onProgress,
            .userData = &observer,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download error handled: {s}\n", .{@errorName(err)});
        return;
    };

    // 2. Error handling test: 404 Not Found
    std.debug.print("\n==> Testing 404 Not Found error handling on https://httpbun.com/status/404...\n", .{});
    _ = client.download(
        "https://httpbun.com/status/404",
        .{
            .path = "downloads/not_found.bin",
            .progress = .quiet,
        },
    ) catch |err| {
        std.debug.print("Correctly caught error for 404: {s}\n", .{
            @errorName(err),
        });
    };

    // 3. Error handling test: Invalid URL
    std.debug.print("\n==> Testing invalid URL error handling...\n", .{});
    _ = client.download(
        "http://invalid.nonexistent.domain.xyz12345/nonexistent",
        .{
            .path = "downloads/invalid.bin",
            .progress = .quiet,
            .maxRetries = 0,
        },
    ) catch |err| {
        std.debug.print("Correctly caught network/URL error: {s}\n", .{
            @errorName(err),
        });
    };
}
```

## Expected Output

```text
==> Downloading https://httpbun.com/bytes/90 with custom progress callback observer...
[Observer Task 101] State: downloading | Progress: 50.0% (45 bytes) | Speed: 12.50 KB/s | ETA: 0s
[Observer Task 101] State: completed | Progress: 100.0% (90 bytes) | Speed: 15.00 KB/s | ETA: 0s

==> Testing 404 Not Found error handling on https://httpbun.com/status/404...
Correctly caught error for 404: HttpStatus404

==> Testing invalid URL error handling...
Correctly caught network/URL error: DnsResolutionFailed
```

Percentages, byte counts, speeds, ETA values, and exact error names vary with network conditions and timing; only the line format above is stable. (ANSI color codes around the state name are omitted here for readability.)

## How to Run

```bash
zig build run-download-custom-progress
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
