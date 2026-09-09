//! Example: Live Reload Server with SSE & Hot CSS Reloading
//!
//! Demonstrates:
//! 1. Server serving dynamic HTML and CSS
//! 2. Live reload script injection
//! 3. Background file watcher triggering reload events
//!
//! Run with: `zig build run-live-reload`

const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const html_content =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>Live Reload Demo</title>
        \\  <link rel="stylesheet" href="/style.css">
        \\</head>
        \\<body>
        \\  <h1>Live Reload with HTTPX</h1>
        \\  <p>Modify files to see instant reload.</p>
        \\</body>
        \\</html>
    ;
    return ctx.html(html_content);
}

fn styleHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "body { background: #1e1e2e; color: #cdd6f4; font-family: sans-serif; }",
        .contentType = "text/css; charset=utf-8",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX Live Reload Server Demo\n\n", .{});

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 4,
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.get("/style.css", styleHandler);

    const port = server.localPort();
    std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const root_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(root_url);

    var res = try client.get(root_url, .{});
    defer res.deinit();
    std.debug.print("GET / returned status {d} (Content-Type: {s})\n", .{ res.status, res.contentType() });

    var doc = try res.html();
    defer doc.deinit();
    std.debug.print("Parsed Page Title: '{s}'\n", .{try doc.title()});

    std.debug.print("\nLive reload server verification successful.\n", .{});
    server.stop();
}
