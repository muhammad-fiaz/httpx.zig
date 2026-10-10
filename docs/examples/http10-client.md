# Example: Http10 Client

Demonstrates http10Client.zig using the canonical HTTPX API.

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
    var response = try client.get("https://httpbun.com/get", .{
        .httpVersion = .http10,
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
}
```

## Expected Output

```text
Status: 200
```

Status code varies with the remote endpoint and network (200 on success).

## How to Run

```bash
zig build run-http10-client
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
