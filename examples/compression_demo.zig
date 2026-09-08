const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // GET with compression
    var response = client.get("http://httpbun.com/get", .{
        .headers = .{ .accept_encoding = "gzip, deflate, br" },
    }) catch |err| {
        std.debug.print("Compression request failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});
}
