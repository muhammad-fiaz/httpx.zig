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

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Multiple requests reuse connection
    var r1 = try client.get("http://httpbun.com/get", .{});
    defer r1.deinit();

    var r2 = try client.get("http://httpbun.com/headers", .{});
    defer r2.deinit();

    std.debug.print("R1 Status: {d}\n", .{r1.status});
    std.debug.print("R2 Status: {d}\n", .{r2.status});
}
```

## Expected Output

```text
R1 Status: 200
R2 Status: 200
```

Status values reflect the live endpoints.

## Run

```bash
zig build run-connection-pool
```

## What to Verify

- Repeated calls succeed with stable performance.
- Pool limits are respected for host and global connections.
