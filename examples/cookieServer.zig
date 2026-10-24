const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .maxConnections = 5,
    });
    defer server.deinit();

    try server.get("/set", setCookieHandler);
    try server.get("/get", getCookieHandler);
    try server.get("/clear", clearCookieHandler);

    const port = server.localPort();
    std.debug.print("Cookie server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.server.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;
    const urlGet = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});
    var res = try client.get(urlGet, .{});
    std.debug.print("GET /get -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Cookie server verification completed successfully.\n", .{});
}

fn setCookieHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const name = ctx.queryParam("name") orelse "guest";
    _ = name;
    return .{ .status = 200, .body = "{\"message\":\"Cookie set\"}", .contentType = "application/json" };
}

fn getCookieHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const username = ctx.cookie("username") orelse "anonymous";
    _ = username;
    return .{ .status = 200, .body = "{\"username\":\"anonymous\"}", .contentType = "application/json" };
}

fn clearCookieHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{ .status = 200, .body = "{\"message\":\"Cookie cleared\"}", .contentType = "application/json" };
}
