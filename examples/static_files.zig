//! Static file server with mount path and index fallback.
//!
//! Run with: `zig build run-static-files`
//!
//! Mounts a directory at `/static`. Files are served with proper Content-Type
//! detection, ETag/If-None-Match support, and a configurable cache header.
//! Directories resolve to `index.html`. Path traversal is rejected.

const std = @import("std");
const httpx = @import("httpx");

fn healthHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "ok" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = false,
        .max_connections = 1,
    });
    defer server.deinit();

    try server.router.add(.GET, "/healthz", &healthHandler);
    try httpx.static.files.register(&server.router, .{
        .root = "examples/static",
        .mount = "/static",
        .index_file = "index.html",
    });
    defer httpx.static.files.unregister();


    const port = server.localPort();
    std.debug.print("serving examples/static on http://127.0.0.1:{d}/static\n", .{port});
    std.debug.print("health endpoint on http://127.0.0.1:{d}/healthz\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/static/index.html", .{port});
    defer allocator.free(url);

    var response = try client.get(.{ .url = url });
    defer response.deinit();

    std.debug.print("GET /static/index.html -> {d} ({d} bytes)\n", .{ response.status, response.body.len });

    t.join();
}
