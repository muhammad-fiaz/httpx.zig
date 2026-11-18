# Example: Dedicated HTTP/1.1 Client

This example demonstrates sending a dedicated HTTP/1.1 client request with custom headers, query parameters, and inspection of response headers and protocol version using the canonical HTTPX client.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn getHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(ctx.allocator, "{{\"query\":\"{s}\",\"status\":\"ok\"}}", .{ctx.query}),
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .limits = .{ .maxConnections = 1 },
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", getHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{
        .allowLfLineEndings = true,
    });
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});

    // Dedicated HTTP/1.1 request with headers and query parameters
    var response = try client.get(url, .{
        .httpVersion = .http11,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "httpx-http11-client/" ++ httpx.version },
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

## Expected Output

```text
Status: 200
Protocol Version: http11
Content-Type: application/json
Body length: 1234 bytes
```

Status, Content-Type, and body length vary with the remote endpoint; version reflects the requested `.http11`.

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
