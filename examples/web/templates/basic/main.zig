const std = @import("std");
const httpx = @import("httpx");

fn homeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.render("index.html", .{
        .title = "HTTPX Native Templates",
        .message = "Hello from high-performance native Zig templates!",
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
        .templates = .{
            .directory = "examples/web/templates/basic/templates",
        },
    });
    defer server.deinit();

    try server.get("/", homeHandler);

    const port = server.localPort();
    std.debug.print("Basic Template Server listening on http://127.0.0.1:{d}\n", .{port});

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
    for (res.headers) |h| {
        std.debug.print("Header: {s} = {s}\n", .{ h.name, h.value });
    }
    std.debug.print("Body bytes: {any}\n", .{res.body[0..@min(res.body.len, 16)]});
    std.debug.print("Response preview:\n{s}\n", .{res.body[0..@min(res.body.len, 250)]});

    server.stop();
}
