const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .max_connections = 2,
    });
    defer server.deinit();

    try server.get("/", indexHandler);

    std.debug.print("Rate-limited server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Implement rate limiting with httpx.RateLimiter in your handler.\n", .{});

    server.run();
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Request successful\"}",
        .content_type = "application/json",
    };
}
