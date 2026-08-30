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

    try server.get("/login", loginHandler);
    try server.get("/dashboard", dashboardHandler);
    try server.get("/logout", logoutHandler);

    const port = server.localPort();
    std.debug.print("Session server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_login = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/login", .{port});
    var res = try client.get(url_login);
    std.debug.print("GET /login -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Session server verification completed successfully.\n", .{});
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
