const std = @import("std");
const httpx = @import("httpx");
const builtin = @import("builtin");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var socket_path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buf, "hx-{d}", .{ts});

    var server = httpx.Server.initWithConfig(allocator, .{
        .unix_path = socket_path,
    });
    defer server.deinit();

    try server.get("/ipc-status", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.json(.{
                .status = "connected",
                .transport = "unix_domain_socket",
                .os = @tagName(builtin.os.tag),
            });
        }
    }.h);

    const thread = server.listenInBackground() catch |err| {
        std.debug.print("\nServer failed to start: {s}\n", .{@errorName(err)});
        if (builtin.os.tag == .windows) {
            std.debug.print("Windows AF_UNIX socket paths have stricter address-length limitations.\n", .{});
            std.debug.print("Use a shorter socket path or run on Linux/macOS.\n", .{});
        }
        return;
    };
    sleepMs(50);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withUnixSocket(socket_path));
    defer client.deinit();

    var resp = client.get("http://localhost/ipc-status", .{}) catch |err| {
        std.debug.print("Request failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer resp.deinit();

    std.debug.print("\nResponse Status: {d}\n", .{resp.status.code});
    std.debug.print("Response Body:\n{s}\n", .{resp.text().?});

    server.stop();
    thread.join();
}
