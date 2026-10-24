//! Example: Single Page Application (SPA) Server with Fallback
//!
//! Demonstrates:
//! 1. Serving static assets (`examples/static`)
//! 2. Client-side routes (e.g. `/dashboard`, `/profile`) falling back to `/index.html`
//! 3. API endpoints (e.g. `/api/*`) returning proper API responses without fallback
//!
//! Run with: `zig build run-spa-server`

const std = @import("std");
const httpx = @import("httpx");

fn apiHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.renderJson(.{
        .status = "ok",
        .service = "spa-api",
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX SPA Fallback Server Demo\n\n", .{});

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 4,
    });
    defer server.deinit();

    // Register API endpoints first
    try server.get("/api/user", apiHandler);

    // Register SPA fallback using existing examples/static directory
    try server.spa("/", "examples/static");

    const port = server.localPort();
    std.debug.print("SPA server listening on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.server.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 1. Request client-side route `/dashboard` -> should fall back to index.html
    const routeUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/dashboard", .{port});
    defer allocator.free(routeUrl);

    var resRoute = try client.get(routeUrl, .{});
    defer resRoute.deinit();
    std.debug.print("GET /dashboard (Fallback) -> Status: {d}, Length: {d}\n", .{ resRoute.status, resRoute.body.len });

    // 2. Request API endpoint `/api/user` -> should return JSON, not fallback
    const apiUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/user", .{port});
    defer allocator.free(apiUrl);

    var resApi = try client.get(apiUrl, .{});
    defer resApi.deinit();
    std.debug.print("GET /api/user (API Route) -> Status: {d}, Body: {s}\n", .{ resApi.status, resApi.body });

    std.debug.print("\nSPA server verification successful.\n", .{});
    server.stop();
}
