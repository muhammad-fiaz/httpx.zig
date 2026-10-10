const std = @import("std");
const httpx = @import("httpx");

fn getHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"status\":\"ok\"}",
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", getHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});

    // Simple retry loop
    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        var response = client.get(url, .{}) catch |err| {
            std.debug.print("Attempt {d} failed: {s}\n", .{ attempts + 1, @errorName(err) });
            httpx.clock.sleepMillis(10);
            continue;
        };
        defer response.deinit();
        std.debug.print("Status: {d}\n", .{response.status});
        return;
    }
    std.debug.print("All retries exhausted\n", .{});
}
