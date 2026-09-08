# Simple Get

Perform a minimal HTTP GET request with `httpx.Client`.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{ .base_url = "https://httpbun.com" });
    defer client.deinit();

    // Unified fetch request
    var res = try client.fetch("https://httpbun.com/get", .{});
    defer res.deinit();

    std.debug.print("status={d}\n", .{res.status});
    std.debug.print("body={s}\n", .{res.bytes()});
}
```

## Run

```bash
zig build run-all-simple_get
```

## What to Verify

- Successful HTTP status code.
- Non-empty response body text.
- Defaults are implicit unless explicitly overridden.
