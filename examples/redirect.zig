const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{
        .follow_redirects = true,
        .max_redirects = 5,
    });
    defer client.deinit();

    // Follows redirects automatically
    var response = try client.get(.{ .url = "http://httpbun.com/redirect/2" });
    defer response.deinit();

    std.debug.print("Final Status: {d}\n", .{response.status});
}
