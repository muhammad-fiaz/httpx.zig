//! Multipart/form-data upload using the client-side API.
//!
//! Run with: `zig build run-multipart`

const std = @import("std");
const httpx = @import("httpx");

fn postHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(ctx.allocator, "{{\"received_bytes\":{d}}}", .{ctx.body.len}),
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
    try server.router.add(.POST, "/post", postHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const fileData = "hello, world!";

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/post", .{port});

    var response = try client.post(url, .{
        .multipart = .{
            .name = "upload",
            .filename = "hello.txt",
            .contentType = "text/plain",
            .data = fileData,
        },
    });
    defer response.deinit();

    std.debug.print("status: {d}\n", .{response.status});
    std.debug.print("body: {s}\n", .{response.body});
}
