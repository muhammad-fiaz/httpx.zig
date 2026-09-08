# Example: Dedicated HTTP/1.1 Client

This example demonstrates sending a dedicated HTTP/1.1 client request with custom headers, query parameters, and inspection of response headers and protocol version using the canonical HTTPX client.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Initialize client once with reusable allocator and I/O
    var client = httpx.Client.init(allocator, io, .{
        .allowLfLineEndings = true,
    });
    defer client.deinit();

    // Dedicated HTTP/1.1 request
    var response = try client.get("http://httpbun.com/get", .{
        .httpVersion = .http11,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "httpx-http11-client/0.2.0" },
        },
        .query = &.{
            .{ .name = "protocol", .value = "http11" },
            .{ .name = "format", .value = "json" },
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Protocol Version: {s}\n", .{@tagName(response.version)});
    if (response.header("content-type")) |ct| {
        std.debug.print("Content-Type: {s}\n", .{ct});
    }
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
}
```

## How to Run

```bash
zig build run-http11-client
```

## Key Highlights

1. **Explicit Version**: Passes `.httpVersion = .http11` in request options.
2. **Resource Management**: The initialized `client` is created once with allocator and IO; individual request calls do not take allocator or IO.
3. **Response Inspection**: Callers can inspect `response.status`, `response.version`, `response.header("name")`, and `response.body`.

## Related

* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Guide: Requests](/guide/requests)
* [API: Client](/api/client)
