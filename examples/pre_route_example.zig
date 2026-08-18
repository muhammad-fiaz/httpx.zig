const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn preRouteHook(ctx: *httpx.Context) anyerror!void {
    const method = @tagName(ctx.request.method);
    const path = ctx.request.uri.path;
    std.debug.print("[preRoute] {s} {s}\n", .{ method, path });
}

fn notFoundHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.status(404).json(.{
        .@"error" = "Not Found",
        .path = ctx.request.uri.path,
    });
}

fn homeHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.text("Welcome home!");
}

fn apiUsersHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.json(.{ .users = &.{ "alice", "bob" } });
}

fn apiItemsHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.json(.{ .items = &.{ 1, 2, 3 } });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();

    try server.preRoute(preRouteHook);

    server.global(notFoundHandler);

    try server.get("/", homeHandler);
    try server.get("/api/users", apiUsersHandler);
    try server.get("/api/items", apiItemsHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    const port = server.listeningPort();

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast()));
    defer client.deinit();

    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base);

    const url1 = try std.fmt.allocPrint(allocator, "{s}/", .{base});
    defer allocator.free(url1);
    var res1 = try client.get(url1, .{});
    defer res1.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res1.status.code, res1.text() orelse "" });

    const url2 = try std.fmt.allocPrint(allocator, "{s}/api/users", .{base});
    defer allocator.free(url2);
    var res2 = try client.get(url2, .{});
    defer res2.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res2.status.code, res2.text() orelse "" });

    const url3 = try std.fmt.allocPrint(allocator, "{s}/nonexistent", .{base});
    defer allocator.free(url3);
    var res3 = try client.get(url3, .{});
    defer res3.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res3.status.code, res3.text() orelse "" });

    server.stop();
    server_thread.join();
}
