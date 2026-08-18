const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn homeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .service = "my-api",
        .version = "1.0.0",
        .status = "running",
    });
}

fn usersHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .users = &.{ "alice", "bob", "charlie" } });
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

    try server.use(httpx.middleware.healthCheck(.{
        .path = "/healthz",
        .body = "{\"status\":\"ok\"}",
    }));

    try server.use(httpx.middleware.readinessProbe(.{
        .path = "/readyz",
        .body = "{\"ready\":true}",
    }));

    try server.get("/", homeHandler);
    try server.get("/api/users", usersHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    const port = server.listeningPort();

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast()));
    defer client.deinit();

    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base);

    const url1 = try std.fmt.allocPrint(allocator, "{s}/healthz", .{base});
    defer allocator.free(url1);
    var res1 = try client.get(url1, .{});
    defer res1.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res1.status.code, res1.text() orelse "" });

    const url2 = try std.fmt.allocPrint(allocator, "{s}/readyz", .{base});
    defer allocator.free(url2);
    var res2 = try client.get(url2, .{});
    defer res2.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res2.status.code, res2.text() orelse "" });

    const url3 = try std.fmt.allocPrint(allocator, "{s}/api/users", .{base});
    defer allocator.free(url3);
    var res3 = try client.get(url3, .{});
    defer res3.deinit();
    std.debug.print("Status: {d}, Body: {s}\n", .{ res3.status.code, res3.text() orelse "" });

    server.stop();
    server_thread.join();
}
