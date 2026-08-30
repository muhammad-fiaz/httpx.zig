//! Multipart/form-data upload using the client-side API.
//!
//! Run with: `zig build run-multipart`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const file_data = "hello, world!";

    var response = try client.post(.{
        .url = "http://httpbun.com/post",
        .multipart = .{
            .field_name = "upload",
            .filename = "hello.txt",
            .content_type = "text/plain",
            .data = file_data,
        },
    });
    defer response.deinit();

    std.debug.print("status: {d}\n", .{response.status});
    std.debug.print("body: {s}\n", .{response.body});
}
