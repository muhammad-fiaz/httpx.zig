# Example: Proxy Demo

Demonstrates proxyDemo.zig using the canonical HTTPX API.

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

    // HTTP proxy (if you have one running)
    // Note: proxy config is set on the request, not client
    var response = client.get("https://httpbun.com/get", .{}) catch |err| {
        std.debug.print("Proxy request failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});
}
```

## Expected Output

```text
Status: 200
Body length: 1234
```

The status code and body length depend on the remote server's response; on proxy failure the program prints `Proxy request failed: <ErrorName>` and returns instead.

## How to Run

```bash
zig build run-proxy-demo
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
