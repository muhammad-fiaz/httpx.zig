# Testing Server

Local integration testing against the real production server pipeline.

## Example

```zig
//! Local integration testing against the real production server pipeline.
//!
//! `httpx.testing.Server` binds a loopback socket, uses the normal
//! `httpx.Client` transport, and reuses the production parser, router,
//! middleware, compression, and lifecycle. It adds ephemeral-port defaults,
//! concise route registration, URL construction, and request capture.

const std = @import("std");
const httpx = @import("httpx");

fn echo(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const body = try std.fmt.allocPrint(ctx.allocator, "{s} {s}: {s}", .{
        ctx.method.toString(),
        ctx.path,
        ctx.body,
    });
    return .{
        .status = 200,
        .body = body,
        .contentType = "text/plain; charset=utf-8",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=== HTTPX testing server demo ===\n", .{});

    var server = try httpx.testing.Server.init(allocator, io, .{});
    defer server.deinit();

    try server.route("/get", httpx.testing.json("{\"message\":\"hello\"}"));
    try server.route("/echo", .{ .method = .POST, .handler = echo });
    try server.route("/redirect", httpx.testing.redirect("/get", 302));
    try server.route("/slow", httpx.testing.delayed(50, httpx.testing.text("slow")));

    try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const getUrl = try server.url("/get");
    defer allocator.free(getUrl);
    var getResponse = try client.get(getUrl, .{});
    defer getResponse.deinit();
    std.debug.print("GET /get -> {d} {s}\n", .{ getResponse.status, getResponse.body });

    const echoUrl = try server.url("/echo");
    defer allocator.free(echoUrl);
    var echoResponse = try client.post(echoUrl, .{ .text = "payload" });
    defer echoResponse.deinit();
    std.debug.print("POST /echo -> {d} {s}\n", .{ echoResponse.status, echoResponse.body });

    const redirectUrl = try server.url("/redirect");
    defer allocator.free(redirectUrl);
    var redirectResponse = try client.get(redirectUrl, .{});
    defer redirectResponse.deinit();
    std.debug.print("GET /redirect (followed) -> {d} {s}\n", .{ redirectResponse.status, redirectResponse.body });

    // A second instance has its own listener, port, routes, capture, and
    // shutdown. Stopping it does not affect the first server.
    var second = try httpx.testing.Server.init(allocator, io, .{});
    defer second.deinit();
    try second.route("/second", httpx.testing.text("second server"));
    try second.start();

    const secondUrl = try second.url("/second");
    defer allocator.free(secondUrl);
    var secondResponse = try client.get(secondUrl, .{});
    defer secondResponse.deinit();
    std.debug.print("GET /second -> {d} {s}\n", .{ secondResponse.status, secondResponse.body });
    second.stop();

    const stillUrl = try server.url("/get");
    defer allocator.free(stillUrl);
    var stillResponse = try client.get(stillUrl, .{});
    defer stillResponse.deinit();
    std.debug.print("first server after second.stop() -> {d}\n", .{stillResponse.status});

    // Capture is bounded (entry count, body bytes, header bytes) and can be
    // inspected after requests complete. The actual method, path, query,
    // headers, and body are all available.
    const captured = try server.requests(allocator);
    defer httpx.testing.freeCaptured(allocator, captured);
    std.debug.print("captured {d} of {d} requests\n", .{
        server.capturedCount(),
        server.requestCount(),
    });
    for (captured) |request| {
        std.debug.print("  {s} {s} ({d} body bytes)\n", .{
            request.method.toString(),
            request.path,
            request.bodySize,
        });
    }
    std.debug.print("route /get handled {d} requests\n", .{server.routeRequestCount("/get")});

    server.stop();
    std.debug.print("=== demo completed ===\n", .{});
}
```

## Run

```bash
zig build run-testing-server
```

## What it demonstrates

- `httpx.testing.Server.init(allocator, io, .{})` with loopback and port-0 defaults.
- Static JSON, text, redirect, and delayed routes.
- A dynamic handler receiving the production `httpx.router.Context`.
- Real `httpx.Client` requests over a real socket.
- A second independent server with its own port, routes, capture, and shutdown.
- Bounded request capture with method, path, and body-size inspection.
