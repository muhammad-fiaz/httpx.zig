const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // Custom headers
    var response = try client.get(.{
        .url = "http://httpbun.com/headers",
        .headers = .{
            .authorization = "Bearer my-token",
            .x_custom = "my-value",
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
