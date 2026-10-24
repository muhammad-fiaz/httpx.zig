const std = @import("std");
const httpx = @import("httpx");

fn liveReloadHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.render("index.html", .{
        .title = "HTTPX Live Reload",
        .message = "File watcher and WebSocket/SSE development reload are running.",
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .watch = true,
        .watchDir = "examples/web/templates/live_reload/templates",
        .liveReload = true,
        .templates = .{
            .directory = "examples/web/templates/live_reload/templates",
        },
    });
    defer server.deinit();

    try server.get("/", liveReloadHandler);
    try server.static("/static", "examples/web/templates/live_reload/static");

    const port = server.localPort();
    std.debug.print("Live Reload Server listening on http://127.0.0.1:{d}\n", .{port});

    const thread = try server.start();
    defer thread.join();

    // Client verification
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/", .{port});

    var res = try client.get(url, .{});
    defer res.deinit();

    std.debug.print("GET / -> Status {d}, Length {d} bytes\n", .{ res.status, res.body.len });

    const cssUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/static/style.css", .{port});
    var cssRes = try client.get(cssUrl, .{});
    defer cssRes.deinit();
    std.debug.print("GET /static/style.css -> Status {d}, Length {d} bytes\n", .{ cssRes.status, cssRes.body.len });

    server.stop();
}
