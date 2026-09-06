const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .max_connections = 5,
    });
    defer server.deinit();

    try server.get("/set", setCookieHandler);
    try server.get("/get", getCookieHandler);
    try server.get("/clear", clearCookieHandler);

    const port = server.localPort();
    std.debug.print("Cookie server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_get = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/get", .{port});
    var res = try client.get(url_get);
    std.debug.print("GET /get -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Cookie server verification completed successfully.\n", .{});
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
