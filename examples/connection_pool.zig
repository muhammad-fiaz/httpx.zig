const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // Multiple requests reuse connection
    var r1 = try client.get(.{ .url = "http://httpbun.com/get" });
    defer r1.deinit();

    var r2 = try client.get(.{ .url = "http://httpbun.com/headers" });
    defer r2.deinit();

    std.debug.print("R1 Status: {d}\n", .{r1.status});
    std.debug.print("R2 Status: {d}\n", .{r2.status});
}
