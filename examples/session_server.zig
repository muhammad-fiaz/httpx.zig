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

    try server.get("/login", loginHandler);
    try server.get("/dashboard", dashboardHandler);
    try server.get("/logout", logoutHandler);

    std.debug.print("Session server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Implement session management with cookies or tokens.\n", .{});

    server.run();
}

fn loginHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged in\",\"user\":\"alice\"}",
        .content_type = "application/json",
    };
}

fn dashboardHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"user\":\"alice\",\"page\":\"dashboard\"}",
        .content_type = "application/json",
    };
}

fn logoutHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged out\"}",
        .content_type = "application/json",
    };
}
