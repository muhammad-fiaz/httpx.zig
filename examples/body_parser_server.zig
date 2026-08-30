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
    try server.post("/api/parse", parseHandler);

    std.debug.print("Body parser server running on http://127.0.0.1:8080\n", .{});
    std.debug.print("POST JSON to /api/parse\n", .{});

    server.run();
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>POST JSON to /api/parse</h1>", .content_type = "text/html" };
}

fn parseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.body.len == 0) {
        return .{ .status = 400, .body = "{\"error\":\"No body\"}", .content_type = "application/json" };
    }
    return ctx.renderJson(.{
        .received = true,
        .length = ctx.body.len,
    });
}
