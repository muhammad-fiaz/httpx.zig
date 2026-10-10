const std = @import("std");
const httpx = @import("httpx");

fn getHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"url\":\"http://127.0.0.1/get\",\"origin\":\"127.0.0.1\"}",
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
    try server.router.add(.GET, "/get", getHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});

    // Unified fetch request
    var response = try client.fetch(url, .{});
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.bytes()});
}
