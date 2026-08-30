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
        .logging = .{ .enabled = true },
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.post("/api/echo", echoHandler);

    std.debug.print("Server running on http://127.0.0.1:8080\n", .{});

    server.run();
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Custom request/response example\"}",
        .content_type = "application/json",
    };
}

fn echoHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.body.len == 0) {
        return .{ .status = 400, .body = "{\"error\":\"No body\"}", .content_type = "application/json" };
    }
    return ctx.renderJson(.{ .echo = ctx.body });
}
