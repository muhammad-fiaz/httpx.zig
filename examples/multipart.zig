//! Multipart/form-data upload using the client-side API.
//!
//! Run with: `zig build run-multipart`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const fileData = "hello, world!";

    var response = try client.post("https://httpbun.com/post", .{
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
