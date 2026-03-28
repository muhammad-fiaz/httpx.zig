//! HTTP/2 High-Level Server Runtime Example for httpx.zig
//!
//! This example runs the high-level `Server` in HTTP/2 mode and serves a route
//! that is consumed by the high-level HTTP/2 client runtime.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreeTcpPort();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .http2_enabled = true,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.get("/h2-server", handleH2);

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server});
    defer server_thread.join();

    std.Thread.sleep(50 * std.time.ns_per_ms);

    var client = httpx.Client.initWithConfig(allocator, .{
        .http2_enabled = true,
        .keep_alive = false,
    });
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/h2-server", .{port});
    defer allocator.free(url);

    var response = client.get(url, .{ .timeout_ms = 5000 }) catch |err| {
        std.debug.print("HTTP/2 client request failed: {s}\n", .{@errorName(err)});
        server.stop();
        return err;
    };
    defer response.deinit();

    std.debug.print("\n=== HTTP/2 Server Runtime Example ===\n", .{});
    std.debug.print("Response version: {s}\n", .{response.version.toString()});
    std.debug.print("Status: {d}\n", .{response.status.code});
    std.debug.print("Body: {s}\n", .{response.text() orelse ""});

    server.stop();
}

fn handleH2(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("hello from http2 server runtime");
}

fn serverThreadMain(server: *httpx.Server) void {
    server.listen() catch |err| {
        if (server.running) {
            std.debug.print("http2 server runtime error: {s}\n", .{@errorName(err)});
        }
    };
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try std.net.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();
    return addr.getPort();
}
