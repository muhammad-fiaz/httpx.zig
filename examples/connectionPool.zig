const std = @import("std");
const httpx = @import("httpx");

fn getHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok-get" };
}

fn headersHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok-headers" };
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
    try server.router.add(.GET, "/get", getHandler, .{});
    try server.router.add(.GET, "/headers", headersHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});
    var r1 = try client.get(url1, .{});
    defer r1.deinit();

    const url2 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/headers", .{port});
    var r2 = try client.get(url2, .{});
    defer r2.deinit();

    server.requestShutdown();
    thread.join();

    std.debug.print("R1 Status: {d}\n", .{r1.status});
    std.debug.print("R2 Status: {d}\n", .{r2.status});
}
