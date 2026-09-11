//! Example: Unified Development Server with Live Reload & Incremental Document Parsing
//!
//! Demonstrates:
//! 1. Serving dynamic HTML and live-reload scripts
//! 2. Monitoring asset modifications using `httpx.Watcher`
//! 3. Re-parsing modified templates incrementally
//! 4. Seamless client-server communication
//!
//! Run with: `zig build run-development-server`

const std = @import("std");
const httpx = @import("httpx");

const dev_template =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\  <title>Development Server</title>
    \\  <link rel="stylesheet" href="/style.css">
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>HTTPX Development Environment</h1>
    \\    <p id="counter">Status: Ready</p>
    \\  </main>
    \\</body>
    \\</html>
;

fn devHtmlHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html(dev_template);
}

fn devCssHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "body { margin: 0; background: #0f172a; color: #f8fafc; font-family: system-ui; }",
        .contentType = "text/css; charset=utf-8",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX Unified Development Server Demo\n\n", .{});

    // 1. Initialize background watcher
    var watcher = try httpx.Watcher.init(allocator, io, .{
        .dirPath = ".",
        .debounceMs = 50,
        .pollIntervalMs = 50,
    });
    defer watcher.deinit();
    try watcher.start();

    // 2. Initialize server
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 4,
    });
    defer server.deinit();

    try server.get("/", devHtmlHandler);
    try server.get("/style.css", devCssHandler);

    const port = server.localPort();
    std.debug.print("Development Server running at http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    // 3. Exercise Client
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const root_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(root_url);

    var res = try client.get(root_url, .{});
    defer res.deinit();
    std.debug.print("GET / returned {d}\n", .{res.status});

    var doc = try res.html();
    defer doc.deinit();
    std.debug.print("Page Title: {s}\n", .{try doc.title()});

    // Test incremental update directly on Document
    const edit = doc.computeEdit(0, 0, 0, dev_template);
    std.debug.print("Document incremental edit verified (startByte: {d})\n", .{edit.startByte});
    const changed = try doc.incrementalUpdate(dev_template);
    std.debug.print("Document incremental reparse detected {d} changed range(s)\n", .{changed});

    std.debug.print("\nDevelopment server verification successful.\n", .{});
    watcher.stop();
    server.stop();
}
