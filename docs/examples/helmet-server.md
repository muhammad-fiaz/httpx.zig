# Example: Helmet Server

Demonstrates helmetServer.zig using the canonical HTTPX API.

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

    try server.use(httpx.middleware.helmet);

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

    var urlBuf: [128]u8 = undefined;
    const urlRoot = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(urlRoot, .{});
    std.debug.print("GET / -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Helmet server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Security headers enabled\"}",
        .contentType = "application/json",
    };
}
```

## Expected Output

```text
Secure server running on http://127.0.0.1:54321
GET / -> status=200, body={"message":"Security headers enabled"}
Helmet server verification completed successfully.
```

Port number varies per run (ephemeral port); status is 200 on success with the JSON body shown.

## How to Run

```bash
zig build run-helmet-server
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
