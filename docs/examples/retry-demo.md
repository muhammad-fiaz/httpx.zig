# Example: Retry Demo

Demonstrates retryDemo.zig using the canonical HTTPX API.

## Complete Example

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

    // Simple retry loop
    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        var response = client.get("https://httpbun.com/get", .{}) catch |err| {
            std.debug.print("Attempt {d} failed: {s}\n", .{ attempts + 1, @errorName(err) });
            httpx.clock.sleepMillis(io, 1000);
            continue;
        };
        defer response.deinit();
        std.debug.print("Status: {d}\n", .{response.status});
        return;
    }
    std.debug.print("All retries exhausted\n", .{});
}
```

## Expected Output

```text
Status: 200
```

On transient failure the loop instead prints `Attempt 1 failed: <ErrorName>` lines (and sleeps 1000 ms between attempts), ending with `All retries exhausted` if all 3 attempts fail. Status codes and error names vary with network conditions.

## How to Run

```bash
zig build run-retry-demo
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
