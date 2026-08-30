//! HTTP/2 Client & Server (h2c) Example.
//!
//! Demonstrates running an HTTP/2 server and performing an HTTP/2 exchange
//! with stream multiplexing and binary framing over TCP.
//! Run with: `zig build run-http2-client`

const std = @import("std");
const httpx = @import("httpx");

fn h2Handler(ctx: *httpx.Context) anyerror!httpx.Response {
    std.debug.print("HTTP/2 Server received: {s} {s}\n", .{ @tagName(ctx.method), ctx.path });
    return .{
        .status = 200,
        .body = "{\"status\":200,\"protocol\":\"HTTP/2\",\"message\":\"Hello from HTTP/2\"}",
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
        .max_connections = 1,
    });
    defer server.deinit();

    try server.get("/h2", h2Handler);
    const port = server.localPort();

    const ServerWorker = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };

    const t = try std.Thread.spawn(.{}, ServerWorker.run, .{&server});
    defer t.join();

    // Client side: connect and perform HTTP/2 request with zero manual IO management
    var client = try httpx.Client.init(allocator, .{
        .http_version = .h2,
    });
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/h2", .{port});
    defer allocator.free(url);

    var resp = try client.get(.{
        .url = url,
        .http_version = .h2,
    });
    defer resp.deinit();

    std.debug.print("HTTP/2 response status: {d}\n", .{resp.status});
    std.debug.print("body: {s}\n", .{resp.body});
}
