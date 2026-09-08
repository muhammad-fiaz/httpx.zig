# Example: Http10 Client

Demonstrates http10_client.zig using the canonical HTTPX API.

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
        .allowLfLineEndings = true,
    });
    defer client.deinit();

    // HTTP/1.0 request
    var response = try client.get("http://httpbun.com/get", .{
        .httpVersion = .http10,
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
}
```

## How to Run

```bash
zig build run-http10-client
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
