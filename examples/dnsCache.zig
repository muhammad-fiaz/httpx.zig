const std = @import("std");
const httpx = @import("httpx");

fn getHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "ok-get" };
}

fn headersHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "ok-headers" };
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
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", getHandler, .{});
    try server.router.add(.GET, "/headers", headersHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{
        .dnsCache = .{
            .enable = true,
            .ttlMs = 60_000,
        },
    });
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});
    var r1 = client.get(url1, .{}) catch |err| {
        std.debug.print("R1 failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer r1.deinit();
    std.debug.print("R1 Status: {d}\n", .{r1.status});

    const url2 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/headers", .{port});
    var r2 = client.get(url2, .{}) catch |err| {
        std.debug.print("R2 failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer r2.deinit();
    std.debug.print("R2 Status: {d}\n", .{r2.status});

    server.requestShutdown();
    thread.join();
}
