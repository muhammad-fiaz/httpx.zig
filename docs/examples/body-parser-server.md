# Example: Body Parser Server

Demonstrates body_parser_server.zig using the canonical HTTPX API.

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
    try server.post("/api/parse", parseHandler);

    const port = server.localPort();
    std.debug.print("Body parser server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_parse = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/parse", .{port});
    var res = try client.post(url_parse, .{ .body = "{\"test\":123}" });
    std.debug.print("POST /api/parse -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Body parser server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>POST JSON to /api/parse</h1>", .contentType = "text/html" };
}

fn parseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.body.len == 0) {
        return .{ .status = 400, .body = "{\"error\":\"No body\"}", .contentType = "application/json" };
    }
    return ctx.renderJson(.{
        .received = true,
        .length = ctx.body.len,
    });
}
```

## How to Run

```bash
zig build run-body-parser-server
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
