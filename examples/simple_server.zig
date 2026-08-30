//! Minimal HTTP/1.1 server with two routes.
//!
//! Run with: `zig build run-simple-server`
//!
//! Demonstrates router registration, the explicit `httpx.Server` lifecycle,
//! and graceful shutdown. The server runs on a background thread; the
//! main thread sends a few requests and then signals shutdown.

const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "hello, world!",
        .content_type = "text/plain; charset=utf-8",
    };
}

fn jsonHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"ok\":true}",
        .content_type = "application/json",
    };
}

fn notFoundHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 404, .body = "not found" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = false,
        .max_connections = 2,
    });
    defer server.deinit();

    try server.router.add(.GET, "/", indexHandler);
    try server.router.add(.GET, "/json", jsonHandler);
    try server.router.add(.GET, "/*rest", notFoundHandler);

    const port = server.localPort();
    std.debug.print("listening on 127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    // Give the worker thread a moment to enter the accept loop. `Thread.yield`
    // is a portable busy-wait primitive; for a real application use a robust
    // readiness signal (semaphore, channel, etc.) rather than a fixed pause.
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);
    var response = try client.get(.{ .url = url });
    defer response.deinit();
    std.debug.print("GET / -> {d} {s}\n", .{ response.status, response.body });

    const json_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/json", .{port});
    defer allocator.free(json_url);
    var json_response = try client.get(.{ .url = json_url });
    defer json_response.deinit();
    std.debug.print("GET /json -> {d} {s}\n", .{ json_response.status, json_response.body });

    t.join();
}
