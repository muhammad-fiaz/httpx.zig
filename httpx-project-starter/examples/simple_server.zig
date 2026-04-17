//! Simple HTTP Server Example
//!
//! Demonstrates creating a basic HTTP server with routing.

const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello, World!");
}

fn jsonHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .message = "Hello from httpx.zig!",
        .version = "1.0.0",
    });
}

fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const user_id = ctx.param("id") orelse "unknown";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "User ID: {s}", .{user_id}) catch "error";
    return ctx.text(msg);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple HTTP Server Example ===\n\n", .{});

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_conflict = .increment,
        .max_port_tries = 32,
        .max_connections = 1000,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/", helloHandler);
    try server.get("/api/status", jsonHandler);
    try server.get("/users/:id", userHandler);
    try server.post("/users", helloHandler);

    std.debug.print("Server Configuration:\n", .{});
    std.debug.print("  Host: {s}\n", .{server.config.host});
    std.debug.print("  Port: {d}\n", .{server.config.port});
    std.debug.print("  Port conflict strategy: {s}\n", .{@tagName(server.config.port_conflict)});
    std.debug.print("  Max port tries: {d}\n", .{server.config.max_port_tries});
    std.debug.print("  Max connections: {d}\n", .{server.config.max_connections});
    std.debug.print("  Keep-alive: {}\n", .{server.config.keep_alive});

    std.debug.print("\nRegistered routes:\n", .{});
    std.debug.print("  GET  /             -> helloHandler\n", .{});
    std.debug.print("  GET  /api/status   -> jsonHandler\n", .{});
    std.debug.print("  GET  /users/:id    -> userHandler\n", .{});
    std.debug.print("  POST /users        -> helloHandler\n", .{});

    std.debug.print("\nServer startup will auto-increment port if 8080 is occupied.\n", .{});
    std.debug.print("Preferred URL: http://127.0.0.1:8080\n", .{});
    std.debug.print("Effective bound port can be read with server.listeningPort() after startup.\n", .{});
    std.debug.print("Try: /, /api/status, /users/123\n", .{});

    try server.listen();
}
