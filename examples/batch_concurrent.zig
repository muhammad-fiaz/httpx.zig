const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello!");
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
        .keep_alive = false,
    });
    defer server.deinit();
    try server.get("/data", helloHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/data", .{port});
    defer allocator.free(base_url);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    var batch1 = httpx.BatchBuilder.init(allocator);
    defer batch1.deinit();
    _ = try batch1.get(base_url);
    _ = try batch1.get(base_url);
    _ = try batch1.get(base_url);

    const all_results = try httpx.all(allocator, &client, batch1.requests.items, .{
        .mode = .single_thread,
    });
    defer {
        for (all_results) |*r| r.deinit();
        allocator.free(all_results);
    }
    std.debug.print("  All completed: {d}/{d} successful\n", .{
        httpx.successfulCount(all_results),
        all_results.len,
    });

    var batch2 = httpx.BatchBuilder.init(allocator);
    defer batch2.deinit();
    _ = try batch2.get(base_url);
    _ = try batch2.get(base_url);
    _ = try batch2.get(base_url);

    const first_2xx = try httpx.any(allocator, &client, batch2.requests.items, .{
        .mode = .single_thread,
    });
    if (first_2xx) |resp| {
        std.debug.print("  Got 2xx: status={d}\n", .{resp.status.code});
        var mut_resp = resp;
        mut_resp.deinit();
    } else {
        std.debug.print("  No 2xx response\n", .{});
    }

    var batch3 = httpx.BatchBuilder.init(allocator);
    defer batch3.deinit();
    _ = try batch3.get(base_url);
    _ = try batch3.get(base_url);
    _ = try batch3.get(base_url);

    var first_done = try httpx.race(allocator, &client, batch3.requests.items, .{
        .mode = .single_thread,
    });
    if (first_done.getResponse()) |resp| {
        std.debug.print("  First completed: status={d}\n", .{resp.status.code});
    } else {
        std.debug.print("  First completed with error\n", .{});
    }
    first_done.deinit();

    var batch4 = httpx.BatchBuilder.init(allocator);
    defer batch4.deinit();
    _ = try batch4.get(base_url);
    _ = try batch4.get(base_url);
    _ = try batch4.get(base_url);

    const settled_results = try httpx.allSettled(allocator, &client, batch4.requests.items, .{
        .mode = .single_thread,
    });
    defer {
        for (settled_results) |*r| r.deinit();
        allocator.free(settled_results);
    }
    std.debug.print("  Settled: {d} total, {d} successful, {d} errors\n", .{
        settled_results.len,
        httpx.successfulCount(settled_results),
        httpx.errorCount(settled_results),
    });

    server.stop();
    server_thread.join();
}
