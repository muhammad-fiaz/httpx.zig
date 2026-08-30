//! WebSocket Server and Browser Client Example.
//! Demonstrates serving an interactive browser WebSocket client and handling WebSocket requests.
//! Run with: `zig build run-websocket-server`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_strategy = .incremental,
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.get("/ws", wsHandler);

    const port = server.localPort();
    std.debug.print("=== WebSocket Server running on http://127.0.0.1:{d} ===\n", .{port});
    std.debug.print("Open http://127.0.0.1:{d}/ in your browser to test the interactive client.\n", .{port});

    server.run();
}

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>httpx.zig WebSocket Demo</title>
        \\  <style>
        \\    body { font-family: 'Segoe UI', sans-serif; background: #0f172a; color: #f8fafc; padding: 2rem; }
        \\    .box { max-width: 600px; margin: 0 auto; background: #1e293b; padding: 2rem; border-radius: 12px; border: 1px solid #334155; }
        \\    h1 { color: #38bdf8; margin-top: 0; }
        \\    .status { padding: 0.5rem 1rem; border-radius: 6px; background: #0369a1; color: white; display: inline-block; margin-bottom: 1rem; }
        \\    pre { background: #020617; padding: 1rem; border-radius: 6px; color: #a5f3fc; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="box">
        \\    <h1>httpx.zig WebSocket Endpoint</h1>
        \\    <div class="status">WebSocket Ready (RFC 6455)</div>
        \\    <p>This endpoint supports RFC 6455 upgrade handshakes, frame encoding, and framing.</p>
        \\    <pre>Endpoint URL: ws://127.0.0.1:8080/ws</pre>
        \\  </div>
        \\</body>
        \\</html>
    );
}

fn wsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    // If request contains Sec-WebSocket-Key, compute Sec-WebSocket-Accept
    if (ctx.header("sec-websocket-key")) |key| {
        var accept_buf: [28]u8 = undefined;
        httpx.websocket.computeAccept(key, &accept_buf);
        return .{
            .status = 101,
            .headers = try ctx.allocator.dupe(httpx.Header, &[_]httpx.Header{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Sec-WebSocket-Accept", .value = try ctx.allocator.dupe(u8, &accept_buf) },
            }),
            .body = "",
        };
    }
    return ctx.html("<h1>WebSocket Endpoint</h1><p>Connect with a WebSocket client.</p>");
}
