const std = @import("std");
const httpx = @import("httpx");

fn okHandler(_: *httpx.Context) anyerror!httpx.Response {
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
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", okHandler, .{});
    try server.router.add(.GET, "/headers", okHandler, .{});
    try server.router.add(.GET, "/ip", okHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var u1Buf: [64]u8 = undefined;
    var u2Buf: [64]u8 = undefined;
    var u3Buf: [64]u8 = undefined;
    const urlGet = try std.fmt.bufPrint(&u1Buf, "http://127.0.0.1:{d}/get", .{port});
    const urlHeaders = try std.fmt.bufPrint(&u2Buf, "http://127.0.0.1:{d}/headers", .{port});
    const urlIp = try std.fmt.bufPrint(&u3Buf, "http://127.0.0.1:{d}/ip", .{port});

    const urls = [_][]const u8{ urlGet, urlHeaders, urlIp };

    // Run all requests concurrently (array passed directly, no explicit & needed).
    // Global-batch slices are page_allocator-owned: deinit each response,
    // then free the slice.
    const results = httpx.getAll(urls) catch |err| {
        std.debug.print("getAll failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer {
        for (results) |*r| r.deinit();
        std.heap.page_allocator.free(results);
    }

    for (results, 0..) |result, i| {
        std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, result.status, result.body.len });
    }

    // Request with options
    const reqs = [_]httpx.RequestOptions{
        .{ .method = .GET, .url = urlGet },
        .{ .method = .GET, .url = urlHeaders },
        .{ .method = .GET, .url = urlIp },
    };

    const results2 = httpx.requestAll(reqs) catch |err| {
        std.debug.print("requestAll failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer {
        for (results2) |*r| r.deinit();
        std.heap.page_allocator.free(results2);
    }

    for (results2) |result| {
        std.debug.print("Status: {d}\n", .{result.status});
    }

    server.requestShutdown();
    thread.join();
}
