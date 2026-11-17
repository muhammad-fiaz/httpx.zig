const std = @import("std");
const httpx = @import("httpx");

fn handler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok" };
}

pub fn main() !void {
    const allocator = @import("allocator.zig").allocator;
    var server = try httpx.Server.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .host = "127.0.0.1",
        .port = 8080,
        .templates = .{ .enabled = false },
        .liveReload = .{ .enabled = false },
        .protocols = .{ .http10 = false, .http11 = true, .http2 = false, .http3 = false },
    });
    defer server.deinit();
    try server.router.get("/", handler, .{});
    server.run();
}
