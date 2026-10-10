# Example: Concurrent Demo

Demonstrates concurrentDemo.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const urls = [_][]const u8{
        "https://httpbun.com/get",
        "https://httpbun.com/headers",
        "https://httpbun.com/ip",
    };

    // Run all requests concurrently (array passed directly, no explicit & needed)
    const results = httpx.getAll(urls) catch |err| {
        std.debug.print("getAll failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer {
        for (results) |*r| r.deinit();
        std.heap.page_allocator.free(results);
    }

    for (results, 0..) |result, i| {
        std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, result.status, result.body.len });
    }

    // Request with options
    const reqs = [_]httpx.RequestOptions{
        .{ .method = .GET, .url = "https://httpbun.com/get" },
        .{ .method = .GET, .url = "https://httpbun.com/headers" },
        .{ .method = .GET, .url = "https://httpbun.com/ip" },
    };

    const results2 = httpx.requestAll(reqs) catch |err| {
        std.debug.print("requestAll failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer {
        for (results2) |*r| r.deinit();
        std.heap.page_allocator.free(results2);
    }

    for (results2) |result| {
        std.debug.print("Status: {d}\n", .{result.status});
    }
}
```

## Expected Output

```text
Request 1: status=200 bodyLen=1234
Request 2: status=200 bodyLen=567
Request 3: status=200 bodyLen=89
Status: 200
Status: 200
Status: 200
```

Status values reflect the live endpoints and body lengths vary per response.

## How to Run

```bash
zig build run-concurrent-demo
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
