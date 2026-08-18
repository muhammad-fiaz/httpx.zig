const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    return (try listener.getLocalAddress()).getPort();
}

fn apiHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .message = "Hello from API!" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreeTcpPort();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.use(httpx.healthCheck(.{
        .path = "/health",
        .body = "{\"status\":\"ok\",\"version\":\"0.1.6\"}",
        .status = 200,
    }));
    try server.use(httpx.readinessProbe(.{
        .path = "/ready",
        .body = "{\"ready\":true,\"checks\":{\"db\":true,\"cache\":true}}",
    }));
    try server.use(httpx.logger());

    try server.get("/api/hello", apiHandler);
    try server.get("/api/users", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.json(.{ .users = &[_][]const u8{ "alice", "bob" } });
        }
    }.h);

    const t = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    const endpoints = [_]struct { path: []const u8, label: []const u8 }{
        .{ .path = "/health", .label = "Health check" },
        .{ .path = "/ready", .label = "Readiness probe" },
        .{ .path = "/api/hello", .label = "API route" },
        .{ .path = "/api/users", .label = "Users route" },
    };

    for (endpoints) |ep| {
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, ep.path });
        defer allocator.free(url);
        var resp = try client.get(url, .{});
        defer resp.deinit();
        std.debug.print("{s: <18} GET {s: <14} -> {d} {s}\n", .{
            ep.label, ep.path, resp.status.code, resp.text().?,
        });
    }

    std.debug.print("healthCheck:    {s}\n", .{httpx.healthCheck(.{}).name});
    std.debug.print("readinessProbe: {s}\n", .{httpx.readinessProbe(.{}).name});

    server.stop();
    t.join();
}
