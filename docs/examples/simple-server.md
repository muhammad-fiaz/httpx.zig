# Simple Server

Start a minimal server with plain-text and JSON routes.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "hello, world!",
        .contentType = "text/plain; charset=utf-8",
    };
}

fn jsonHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "{\"ok\":true}",
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
        .enableDocs = false,
        .maxConnections = 2,
    });
    defer server.deinit();

    try server.router.add(.GET, "/", indexHandler, .{});
    try server.router.add(.GET, "/json", jsonHandler, .{});

    const port = server.localPort();
    std.debug.print("listening on 127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);
    var response = try client.get(url, .{});
    defer response.deinit();
    std.debug.print("GET / -> {d} {s}\n", .{ response.status, response.body });

    const jsonUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/json", .{port});
    defer allocator.free(jsonUrl);
    var jsonResponse = try client.get(jsonUrl, .{});
    defer jsonResponse.deinit();
    std.debug.print("GET /json -> {d} {s}\n", .{ jsonResponse.status, jsonResponse.body });

    t.join();
}
```

## Expected Output

```text
listening on 127.0.0.1:41237
GET / -> 200 hello, world!
GET /json -> 200 {"ok":true}
```

The port is the ephemeral port selected at runtime, and statuses/bodies vary with the registered routes and requests.

## Run

```bash
zig build run-simple-server
```

## What to Verify

- `GET /` returns `hello, world!` as plain text.
- `GET /json` returns `{"ok":true}` as JSON.
- Server starts without route registration errors.
- A client request to `http://127.0.0.1:<effective-port>/` returns immediately.
