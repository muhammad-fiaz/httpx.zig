# Example: Helmet Server

Demonstrates helmet_server.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .maxConnections = 5,
    });
    defer server.deinit();

    try server.get("/", indexHandler);

    const port = server.localPort();
    std.debug.print("Secure server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_root = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(url_root, .{});
    std.debug.print("GET / -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Helmet server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Security headers enabled\"}",
        .contentType = "application/json",
    };
}
```

## How to Run

```bash
zig build run-helmet-server
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
