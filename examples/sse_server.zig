const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .max_connections = 5,
    });
    defer server.deinit();

    try server.get("/events", sseHandler);

    const port = server.localPort();
    std.debug.print("SSE server running on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_events = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/events", .{port});
    var res = try client.get(url_events, .{});
    std.debug.print("GET /events -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("SSE server verification completed successfully.\n", .{});
}

fn sseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    var out = std.ArrayList(u8).empty;
    var writer = httpx.sse.Writer.EventWriter.init(ctx.allocator);
    try writer.writeEvent(&out, &[_][]const u8{"Connected to SSE live stream"}, "status", 1, 5000);
    try writer.writeEvent(&out, &[_][]const u8{"First data packet"}, "message", 2, null);

    return .{
        .status = 200,
        .body = out.items,
        .content_type = "text/event-stream; charset=utf-8",
        .headers = try ctx.allocator.dupe(httpx.router.Header, &[_]httpx.router.Header{
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Connection", .value = "keep-alive" },
        }),
    };
}
