//! HTTP/3 High-Level Server Runtime Example for httpx.zig
//!
//! This example runs the high-level `Server` in HTTP/3 mode over UDP and serves
//! a route that is consumed by the high-level HTTP/3 client runtime.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== HTTP/3 Server Runtime Example ===\n\n", .{});

    var port = try pickFreeUdpPort();
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        if (attempts >= 3) {
            std.debug.print("  Could not bind after 3 attempts - skipping.\n", .{});
            return;
        }
        var server = httpx.Server.initWithConfig(allocator, .{
            .host = "127.0.0.1",
            .port = port,
            .http3_enabled = true,
            .http2_enabled = false,
            .keep_alive = false,
        });
        server.get("/h3-server", handleH3) catch |err| {
            std.debug.print("  Route registration failed: {}\n", .{err});
            server.deinit();
            return;
        };
        const t = server.listenInBackground() catch |err| {
            std.debug.print("  Bind failed on port {d}: {} - retrying...\n", .{ port, err });
            server.deinit();
            sleepMs(200);
            port = try pickFreeUdpPort();
            continue;
        };
        defer server.deinit();

        sleepMs(100);
        std.debug.print("  Server listening on port {d}\n", .{port});

        var client = httpx.Client.initWithConfig(allocator, .{
            .http3_enabled = true,
            .http2_enabled = false,
        });
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/h3-server", .{port});
        defer allocator.free(url);

        var response = client.get(url, .{ .timeout_ms = 10_000 }) catch |err| {
            std.debug.print("  Client request failed: {}\n", .{err});
            return;
        };
        defer response.deinit();

        std.debug.print("Response version: {s}\n", .{response.version.toString()});
        std.debug.print("Status: {d}\n", .{response.status.code});
        std.debug.print("Body: {s}\n", .{response.text() orelse ""});

        server.stop();
        t.join();
        return;
    }
}

fn handleH3(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("hello from http3 server runtime");
}

fn pickFreeUdpPort() !u16 {
    var socket = try httpx.UdpSocket.create();
    defer socket.close();

    try socket.bind(try httpx.Address.parseIp("127.0.0.1", 0));
    const addr = try socket.getLocalAddress();
    return addr.getPort();
}
