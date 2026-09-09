const std = @import("std");
const httpx = @import("httpx");

fn liveReloadHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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

    var server = try httpx.Server.init(allocator, io, .{
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

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var res = try client.get(url, .{});
    defer res.deinit();

    std.debug.print("GET / -> Status {d}, Length {d} bytes\n", .{ res.status, res.body.len });

    const css_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/static/style.css", .{port});
    var css_res = try client.get(css_url, .{});
    defer css_res.deinit();
    std.debug.print("GET /static/style.css -> Status {d}, Length {d} bytes\n", .{ css_res.status, css_res.body.len });

    server.stop();
}
