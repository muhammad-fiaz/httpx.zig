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
    try server.post("/api/parse", parseHandler);

    const port = server.localPort();
    std.debug.print("Body parser server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_parse = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/parse", .{port});
    var res = try client.post(.{ .url = url_parse, .body = "{\"test\":123}" });
    std.debug.print("POST /api/parse -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("Body parser server verification completed successfully.\n", .{});
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
