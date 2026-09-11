# Connection Pool

Reuse connections across requests to improve latency and throughput.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .pool = .{ .maxConnections = 32, .maxPerHost = 8 },
    });
    defer client.deinit();

    inline for (0..5) |_| {
        var res = try client.get("https://httpbun.com/get", .{});
        defer res.deinit();
        std.debug.print("status={d}, len={d}\n", .{ res.status, res.body.len });
    }
}
```

## Run

```bash
zig build run-connection-pool
```

## What to Verify

- Repeated calls succeed with stable performance.
- Pool limits are respected for host and global connections.
