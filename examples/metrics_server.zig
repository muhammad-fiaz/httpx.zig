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
    try server.get("/api/data", dataHandler);

    std.debug.print("Metrics server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Add /metrics endpoint with your own metrics collection.\n", .{});

    server.run();
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>Metrics Example</h1>", .content_type = "text/html" };
}

fn dataHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"data\":\"some value\",\"count\":42}", .content_type = "application/json" };
}
