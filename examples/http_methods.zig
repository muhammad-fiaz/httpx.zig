const std = @import("std");
const httpx = @import("httpx");

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("OK");
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

    const methods = [_]httpx.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS, .TRACE, .CONNECT };
    for (methods) |m| {
        std.debug.print("  {s: <10} idempotent={}  safe={}  hasBody={}  hasResponse={}\n", .{
            @tagName(m),
            m.isIdempotent(),
            m.isSafe(),
            m.hasRequestBody(),
            m.hasResponseBody(),
        });
    }

    const method_strings = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "CUSTOM" };
    for (method_strings) |s| {
        if (httpx.Method.fromString(s)) |m| {
            std.debug.print("  \"{s}\" -> {s}\n", .{ s, @tagName(m) });
        } else {
            std.debug.print("  \"{s}\" -> unknown\n", .{s});
        }
    }

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer server.deinit();

    try server.get("/resource", handler);
    try server.post("/resource", handler);
    try server.put("/resource", handler);
    try server.patch("/resource", handler);
    try server.delete("/resource", handler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/resource", .{port});
    defer allocator.free(base_url);

    var get_resp = try client.get(base_url, .{});
    defer get_resp.deinit();
    std.debug.print("  GET    -> {d}\n", .{get_resp.status.code});

    var post_resp = try client.post(base_url, .{ .body = "create" });
    defer post_resp.deinit();
    std.debug.print("  POST   -> {d}\n", .{post_resp.status.code});

    var put_resp = try client.put(base_url, .{ .body = "update" });
    defer put_resp.deinit();
    std.debug.print("  PUT    -> {d}\n", .{put_resp.status.code});

    var patch_resp = try client.patch(base_url, .{ .body = "patch" });
    defer patch_resp.deinit();
    std.debug.print("  PATCH  -> {d}\n", .{patch_resp.status.code});

    var del_resp = try client.delete(base_url, .{});
    defer del_resp.deinit();
    std.debug.print("  DELETE -> {d}\n", .{del_resp.status.code});

    var head_resp = try client.head(base_url, .{});
    defer head_resp.deinit();
    std.debug.print("  HEAD   -> {d}\n", .{head_resp.status.code});

    var opts_resp = try client.options(base_url, .{});
    defer opts_resp.deinit();
    std.debug.print("  OPTIONS -> {d}\n", .{opts_resp.status.code});

    server.stop();
    server_thread.join();
}
