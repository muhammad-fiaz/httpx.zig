const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // POST with JSON
    var response = try client.post(.{
        .url = "http://httpbun.com/post",
        .json = "{\"name\":\"Alice\"}",
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
