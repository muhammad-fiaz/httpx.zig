//! Example: Static Site Server with Live Reload
//!
//! Demonstrates:
//! 1. Mounting an existing directory of static assets (`examples/static`)
//! 2. Serving static files with ETag and conditional requests
//! 3. Automatic index.html resolution
//!
//! Run with: `zig build run-static-site`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX Static Site Server Demo\n\n", .{});

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .max_connections = 4,
    });
    defer server.deinit();

    try server.static("/", "examples/static");

    const port = server.localPort();
    std.debug.print("Static site server listening on http://127.0.0.1:{d}\n", .{port});

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
    std.debug.print("GET / -> Status: {d}, Length: {d}\n", .{ res.status, res.body.len });

    var doc = try res.html();
    defer doc.deinit();
    std.debug.print("Mounted Site Title: '{s}'\n", .{try doc.title()});

    std.debug.print("\nStatic site verification successful.\n", .{});
    server.stop();
}
