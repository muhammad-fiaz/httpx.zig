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

    try server.get("/events", sseHandler);

    std.debug.print("SSE server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Subscribe to events at http://127.0.0.1:8080/events\n", .{});

    server.run();
}

fn sseHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>SSE endpoint</h1><p>EventSource clients can subscribe here.</p>", .content_type = "text/html" };
}
