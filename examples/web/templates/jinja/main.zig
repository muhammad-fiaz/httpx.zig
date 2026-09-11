const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.render("index.html", .{
        .title = "HTTPX Jinja Demo",
        .heading = "Team Directory",
        .users = [_]struct { name: []const u8, role: []const u8, age: i32 }{
            .{ .name = " ada lovelace ", .role = "admin", .age = 36 },
            .{ .name = "grace hopper", .role = "member", .age = 15 },
            .{ .name = "alan turing", .role = "member", .age = 10 },
        },
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
            .directory = "examples/web/templates/jinja/templates",
        },
    });
    defer server.deinit();

    try server.get("/", indexHandler);

    const port = server.localPort();
    std.debug.print("Jinja Template Server listening on http://127.0.0.1:{d}\n", .{port});

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
