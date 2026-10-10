const std = @import("std");
const httpx = @import("httpx");

fn headersHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"headers\":{");
    for (ctx.headers, 0..) |h, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, ",");
        try out.print(ctx.allocator, "\"{s}\":\"{s}\"", .{ h.name, h.value });
    }
    try out.appendSlice(ctx.allocator, "}}");
    return .{
        .status = 200,
        .body = try ctx.allocator.dupe(u8, out.items),
        .contentType = "application/json",
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
        .maxConnections = 1,
    });
    defer server.deinit();
    try server.router.add(.GET, "/headers", headersHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/headers", .{port});

    // Custom headers
    var response = try client.get(url, .{
        .headers = .{
            .authorization = "Bearer my-token",
            .xCustom = "my-value",
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
