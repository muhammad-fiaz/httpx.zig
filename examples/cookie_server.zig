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

    try server.get("/set", setCookieHandler);
    try server.get("/get", getCookieHandler);
    try server.get("/clear", clearCookieHandler);

    std.debug.print("Cookie server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("Try: http://127.0.0.1:8080/set?name=alice\n", .{});
    std.debug.print("Try: http://127.0.0.1:8080/get\n", .{});

    server.run();
}

fn setCookieHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const name = ctx.queryParam("name") orelse "guest";
    _ = name;
    return .{ .status = 200, .body = "{\"message\":\"Cookie set\"}", .content_type = "application/json" };
}

fn getCookieHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const username = ctx.cookie("username") orelse "anonymous";
    _ = username;
    return .{ .status = 200, .body = "{\"username\":\"anonymous\"}", .content_type = "application/json" };
}

fn clearCookieHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"message\":\"Cookie cleared\"}", .content_type = "application/json" };
}
