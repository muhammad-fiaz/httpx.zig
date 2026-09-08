# Example: Redirect

Demonstrates redirect.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .followRedirects = true,
        .maxRedirects = 5,
    });
    defer client.deinit();

    // Follows redirects automatically
    var response = try client.get("http://httpbun.com/redirect/2", .{});
    defer response.deinit();

    std.debug.print("Final Status: {d}\n", .{response.status});
}
```

## How to Run

```bash
zig build run-redirect
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
