const std = @import("std");
const httpx = @import("httpx");

fn inheritanceHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.render("index.html", .{
        .title = "HTTPX Inheritance Demo",
        .heading = "Template Inheritance Works!",
        .description = "This page extends base.html and overrides the content block dynamically.",
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
            .directory = "examples/web/templates/inheritance/templates",
        },
    });
    defer server.deinit();

    try server.get("/", inheritanceHandler);

    const port = server.localPort();
    std.debug.print("Inheritance Template Server listening on http://127.0.0.1:{d}\n", .{port});

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
    std.debug.print("Rendered HTML:\n{s}\n", .{res.body});

    server.stop();
}
