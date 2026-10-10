const std = @import("std");
const httpx = @import("httpx");

fn redirectHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.redirect("/final", 302);
}

fn finalHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "redirected successfully",
        .contentType = "text/plain",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();
    try server.router.add(.GET, "/redirect/1", redirectHandler, .{});
    try server.router.add(.GET, "/final", finalHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{
        .followRedirects = true,
        .maxRedirects = 5,
    });
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/redirect/1", .{port});

    // Follows redirects automatically
    var response = try client.get(url, .{});
    defer response.deinit();

    server.requestShutdown();
    thread.join();

    std.debug.print("Final Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
