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

    try server.get("/", indexHandler);
    try server.get("/api/data", dataHandler);

    const port = server.localPort();
    std.debug.print("Metrics server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_data = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/data", .{port});
    var res = try client.get(url_data);
    std.debug.print("GET /api/data -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Metrics server verification completed successfully.\n", .{});
}

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "<h1>Metrics Example</h1>", .content_type = "text/html" };
}

fn dataHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "{\"data\":\"some value\",\"count\":42}", .content_type = "application/json" };
}
