const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{
        .allow_lf_line_endings = true,
    });
    defer client.deinit();

    // HTTP/1.0 request
    var response = try client.get(.{
        .url = "http://httpbun.com/get",
        .http_version = .http_1_0,
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
}
