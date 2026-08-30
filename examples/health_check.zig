//! Health, readiness, and metrics endpoints.
//!
//! Run with: `zig build run-health-check`
//!
//! Demonstrates the health check helpers, custom metrics, and a
//! readiness probe that gates traffic.

const std = @import("std");
const httpx = @import("httpx");

fn healthzHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = httpx.health.Status.healthy.httpStatus(),
        .body = httpx.health.Status.healthy.jsonBody(),
        .content_type = "application/json",
    };
}

fn readyzHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = httpx.health.Status.ready.httpStatus(),
        .body = httpx.health.Status.ready.jsonBody(),
        .content_type = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = false,
        .max_connections = 2,
    });
    defer server.deinit();

    try server.router.add(.GET, "/healthz", &healthzHandler);
    try server.router.add(.GET, "/readyz", &readyzHandler);

    const port = server.localPort();
    std.debug.print("endpoints on 127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const health_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/healthz", .{port});
    defer allocator.free(health_url);
    var health_res = try client.get(.{ .url = health_url });
    defer health_res.deinit();
    std.debug.print("GET /healthz -> {d} {s}\n", .{ health_res.status, health_res.body });

    const ready_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/readyz", .{port});
    defer allocator.free(ready_url);
    var ready_res = try client.get(.{ .url = ready_url });
    defer ready_res.deinit();
    std.debug.print("GET /readyz -> {d} {s}\n", .{ ready_res.status, ready_res.body });

    t.join();
}
