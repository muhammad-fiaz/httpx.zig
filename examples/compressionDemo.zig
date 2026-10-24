const std = @import("std");
const httpx = @import("httpx");

fn getHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "{\"compressed\":false,\"message\":\"compression demo response payload\"}",
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
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

    // GET with compression (struct-literal headers use camelCase names,
    // normalized to wire names: acceptEncoding -> Accept-Encoding).
    var response = client.get(url, .{
        .headers = .{ .acceptEncoding = "gzip, deflate, br" },
    }) catch |err| {
        std.debug.print("Compression request failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});
}
