const std = @import("std");
const httpx = @import("httpx");

fn handler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok" };
}

pub fn main() !void {
    const allocator = @import("allocator.zig").allocator;
    var router = httpx.Router.init(allocator, .{});
    defer router.deinit();
    try router.get("/", handler, .{});
    var context = httpx.router.Context{
        .allocator = allocator,
        .method = .GET,
        .path = "/",
    };
    const response = router.dispatch(&context);
    std.debug.print("{d}\n", .{response.status});
}
