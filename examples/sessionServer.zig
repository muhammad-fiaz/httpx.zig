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

    try server.get("/login", loginHandler);
    try server.get("/dashboard", dashboardHandler);
    try server.get("/logout", logoutHandler);

    const port = server.localPort();
    std.debug.print("Session server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.server.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;
    const urlLogin = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/login", .{port});
    var res = try client.get(urlLogin, .{});
    std.debug.print("GET /login -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Session server verification completed successfully.\n", .{});
}

fn loginHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged in\",\"user\":\"alice\"}",
        .contentType = "application/json",
    };
}

fn dashboardHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "{\"user\":\"alice\",\"page\":\"dashboard\"}",
        .contentType = "application/json",
    };
}

fn logoutHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body = "{\"message\":\"Logged out\"}",
        .contentType = "application/json",
    };
}
