const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello, World!");
}

fn jsonHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .message = "Hello from httpx.zig!",
        .version = "1.0.0",
    });
}

fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const user_id = ctx.param("id") orelse "unknown";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "User ID: {s}", .{user_id}) catch "error";
    return ctx.text(msg);
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .max_connections = 1000,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/", helloHandler);
    try server.get("/api/status", jsonHandler);
    try server.get("/users/:id", userHandler);
    try server.post("/users", helloHandler);

    const server_thread = try server.listenInBackground();

    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    const hello_url = try std.fmt.allocPrint(allocator, "{s}/", .{base_url});
    defer allocator.free(hello_url);
    const status_url = try std.fmt.allocPrint(allocator, "{s}/api/status", .{base_url});
    defer allocator.free(status_url);
    const user_url = try std.fmt.allocPrint(allocator, "{s}/users/123", .{base_url});
    defer allocator.free(user_url);

    var resp1 = try client.get(hello_url, .{});
    defer resp1.deinit();
    std.debug.print("\nGET / -> status: {d}, body: {s}\n", .{ resp1.status.code, resp1.text() orelse "" });

    var resp2 = try client.get(status_url, .{});
    defer resp2.deinit();
    std.debug.print("GET /api/status -> status: {d}, body: {s}\n", .{ resp2.status.code, resp2.text() orelse "" });

    var resp3 = try client.get(user_url, .{});
    defer resp3.deinit();
    std.debug.print("GET /users/123 -> status: {d}, body: {s}\n", .{ resp3.status.code, resp3.text() orelse "" });

    server.stop();
    server_thread.join();
}
