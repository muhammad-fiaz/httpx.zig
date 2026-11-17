const std = @import("std");
const httpx = @import("httpx");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var server = try httpx.Server.init(gpa.allocator(), std.Io.Threaded.global_single_threaded.io(), .{});
    defer server.deinit();
    try httpx.docs.mount(&server, .{ .swagger = .{ .enabled = false }, .redoc = .{ .enabled = false }, .scalar = .{ .enabled = false }, .graphiql = .{ .enabled = false } });
}
