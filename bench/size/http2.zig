const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = @import("allocator.zig").allocator;
    var client = httpx.Client.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{});
    defer client.deinit();
    var response = try client.get("http://127.0.0.1:1/", .{ .httpVersion = .http2 });
    defer response.deinit();
    std.debug.print("{d}\n", .{response.status});
}
