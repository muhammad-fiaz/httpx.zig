# Transfer Progress

Track download/upload progress with percentage, speed, ETA, and cancellation.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn onProgress(p: httpx.Progress) void {
    if (p.percentage()) |pct| {
        std.debug.print("Progress: {d:.1}% ({d}/{d} bytes)\n", .{ pct, p.bytes_transferred, p.total_bytes orelse 0 });
    } else {
        std.debug.print("Transferred: {d} bytes\n", .{p.bytes_transferred});
    }
    std.debug.print("Speed: {d} bytes/sec\n", .{p.bytesPerSecond()});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const p = httpx.Progress{
        .bytes_transferred = 500,
        .total_bytes = 1000,
        .elapsed_ns = std.time.ns_per_s,
    };
    onProgress(p);

    std.debug.print("ETA: ", .{});
    if (p.estimatedRemainingNs()) |eta_ns| {
        std.debug.print("{d:.1}s\n", .{@as(f64, @floatFromInt(eta_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))});
    } else {
        std.debug.print("unknown\n", .{});
    }

    var token = httpx.CancelToken{};
    std.debug.print("Cancelled: {}\n", .{token.isCancelled()});
}
```

## Run

```bash
zig build run-all-progress_example
```

## What to Verify

- Progress percentage is calculated correctly.
- Bytes-per-second speed is reported.
- ETA is computed based on transfer rate.
- CancelToken starts in a non-cancelled state.
