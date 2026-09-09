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

fn apiHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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

    var server = try httpx.Server.init(allocator, io, .{
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
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 1. Request client-side route `/dashboard` -> should fall back to index.html
    const route_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/dashboard", .{port});
    defer allocator.free(route_url);

    var res_route = try client.get(route_url, .{});
    defer res_route.deinit();
    std.debug.print("GET /dashboard (Fallback) -> Status: {d}, Length: {d}\n", .{ res_route.status, res_route.body.len });

    // 2. Request API endpoint `/api/user` -> should return JSON, not fallback
    const api_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/user", .{port});
    defer allocator.free(api_url);

    var res_api = try client.get(api_url, .{});
    defer res_api.deinit();
    std.debug.print("GET /api/user (API Route) -> Status: {d}, Body: {s}\n", .{ res_api.status, res_api.body });

    std.debug.print("\nSPA server verification successful.\n", .{});
    server.stop();
}
