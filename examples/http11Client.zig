const std = @import("std");
const httpx = @import("httpx");

fn getHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(ctx.allocator, "{{\"query\":\"{s}\",\"status\":\"ok\"}}", .{ctx.query}),
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

    var client = httpx.Client.init(allocator, io, .{
        .allowLfLineEndings = true,
    });
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});

    // Dedicated HTTP/1.1 request with headers and query parameters
    var response = try client.get(url, .{
        .httpVersion = .http11,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "httpx-http11-client/0.2.0" },
        },
        .query = &.{
            .{ .name = "protocol", .value = "http11" },
            .{ .name = "format", .value = "json" },
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Protocol Version: {s}\n", .{@tagName(response.version)});
    if (response.header("content-type")) |ct| {
        std.debug.print("Content-Type: {s}\n", .{ct});
    }
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
}
