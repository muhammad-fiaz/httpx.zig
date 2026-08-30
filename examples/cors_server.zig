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

    try server.get("/api/data", dataHandler);
    try server.post("/api/data", createHandler);

    std.debug.print("CORS server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Add CORS headers manually in your proxy/load balancer.\n", .{});

    server.run();
}

fn dataHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"data\":\"CORS enabled\"}", .content_type = "application/json" };
}

fn createHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 201, .body = "{\"created\":true}", .content_type = "application/json" };
}
