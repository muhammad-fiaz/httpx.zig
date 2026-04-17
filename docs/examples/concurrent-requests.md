# Concurrent Requests

Execute many requests in parallel with shared client configuration.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    const urls = [_][]const u8{
        "https://httpbin.org/get?a=1",
        "https://httpbin.org/get?a=2",
        "https://httpbin.org/get?a=3",
    };

    var responses: [urls.len]httpx.Response = undefined;
    defer for (responses) |*r| r.deinit();

    for (urls, 0..) |url, i| {
        responses[i] = try client.get(url, .{});
    }

    for (responses, 0..) |r, i| {
        std.debug.print("req {d}: status={d}\n", .{ i, r.status.code });
    }
}
```

## Run

```bash
zig build run-concurrent_requests
```

## What to Verify

- All requests return successful status codes.
- Responses are handled independently without shared-state corruption.
