//! Health endpoints: liveness and readiness as data, not strings.
//!
//! Run with: `zig build run-health-check`

const std = @import("std");
const httpx = @import("httpx");

fn health(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "{\"status\":\"healthy\"}", .contentType = "application/json" };
}

fn ready(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "{\"status\":\"ready\"}", .contentType = "application/json" };
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
        .maxConnections = 2,
    });
    defer server.deinit();

    try server.get("/health", .{ .handler = health });
    try server.get("/ready", .{ .handler = ready });

    const port = server.localPort();
    std.debug.print("endpoints on 127.0.0.1:{d}\n", .{port});

    const t = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const healthUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/health", .{port});
    defer allocator.free(healthUrl);
    var healthRes = try client.get(healthUrl, .{});
    defer healthRes.deinit();
    std.debug.print("GET /health -> {d} {s}\n", .{ healthRes.status, healthRes.body });

    const readyUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/ready", .{port});
    defer allocator.free(readyUrl);
    var readyRes = try client.get(readyUrl, .{});
    defer readyRes.deinit();
    std.debug.print("GET /ready -> {d} {s}\n", .{ readyRes.status, readyRes.body });

    server.requestShutdown();
    t.join();
}
