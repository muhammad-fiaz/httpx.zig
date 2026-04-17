//! Middleware Example
//!
//! Demonstrates using middleware for cross-cutting concerns.

const std = @import("std");
const httpx = @import("httpx");

fn apiHandler(_: *httpx.Context) anyerror!httpx.Response {
    unreachable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Middleware Example ===\n\n", .{});

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.use(httpx.logger());
    try server.use(httpx.cors(.{
        .allowed_origins = &.{ "https://example.com", "https://app.example.com" },
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE },
        .allow_credentials = true,
    }));
    try server.use(httpx.rateLimit(.{
        .max_requests = 100,
        .window_ms = 60_000,
    }));
    try server.use(httpx.helmet());
    try server.use(httpx.compression());

    try server.get("/api/data", apiHandler);

    std.debug.print("Middleware Stack:\n", .{});
    std.debug.print("-----------------\n", .{});
    for (server.middleware.items, 0..) |mw, i| {
        std.debug.print("  {d}. {s}\n", .{ i + 1, mw.name });
    }

    std.debug.print("\nAvailable Middleware:\n", .{});
    std.debug.print("  - logger(): Request/response logging\n", .{});
    std.debug.print("  - cors(): Cross-Origin Resource Sharing\n", .{});
    std.debug.print("  - rateLimit(): Request rate limiting\n", .{});
    std.debug.print("  - helmet(): Security headers\n", .{});
    std.debug.print("  - compression(): Response compression\n", .{});
    std.debug.print("  - basicAuth(): HTTP Basic authentication\n", .{});
    std.debug.print("  - bodyParser(): Request body parsing\n", .{});
    std.debug.print("  - timeout(): Request timeout\n", .{});
    std.debug.print("  - requestId(): Unique request ID\n", .{});

    std.debug.print("\nCORS Configuration:\n", .{});
    const cors_config = httpx.middleware.CorsConfig{
        .allowed_origins = &.{"*"},
        .allow_credentials = false,
        .max_age = 86400,
    };
    std.debug.print("  Max age: {d}s\n", .{cors_config.max_age});
    std.debug.print("  Allow credentials: {}\n", .{cors_config.allow_credentials});

    std.debug.print("\nRate Limit Configuration:\n", .{});
    const rate_config = httpx.middleware.RateLimitConfig{
        .max_requests = 100,
        .window_ms = 60_000,
    };
    std.debug.print("  Max requests: {d}\n", .{rate_config.max_requests});
    std.debug.print("  Window: {d}ms\n", .{rate_config.window_ms});
}
