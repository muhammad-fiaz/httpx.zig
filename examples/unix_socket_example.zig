//! Unix Domain Socket Example
//!
//! Demonstrates httpx.zig's IPC (Inter-Process Communication) support:
//! - Running an HTTP server listening on a Unix domain socket path
//! - Connecting an HTTP client to the Unix domain socket path
//! - Executing GET requests and parsing responses
//!
//! Unix domain sockets are available on:
//!   - Linux (all versions)
//!   - macOS (all versions)
//!   - Windows 10 build 17061+ (requires Developer Mode or elevated privileges)

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

    std.debug.print("=== Unix Domain Socket Example ===\n\n", .{});
    std.debug.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});

    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var socket_path_buf: [64]u8 = undefined;
    // Use short name to stay within Windows AF_UNIX 108-byte limit
    const socket_path = try std.fmt.bufPrint(&socket_path_buf, "hx-{d}", .{ts});

    // 1. Initialize and configure HTTP Server on Unix Socket
    std.debug.print("Initializing server on: {s}...\n", .{socket_path});
    var server = httpx.Server.initWithConfig(allocator, .{
        .unix_path = socket_path,
    });
    defer server.deinit();

    // Register a test route
    try server.get("/ipc-status", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.json(.{
                .status = "connected",
                .transport = "unix_domain_socket",
                .os = @tagName(builtin.os.tag),
            });
        }
    }.h);

    // 2. Start the server asynchronously
    const thread = server.listenInBackground() catch |err| {
        std.debug.print("\nServer failed to start: {s}\n", .{@errorName(err)});
        if (builtin.os.tag == .windows) {
            std.debug.print("Windows AF_UNIX socket paths have stricter address-length limitations.\n", .{});
            std.debug.print("Use a shorter socket path or run on Linux/macOS.\n", .{});
        }
        std.debug.print("=== Unix Domain Socket Example Skipped (bind failed) ===\n", .{});
        return;
    };
    sleepMs(50);

    // 3. Initialize HTTP Client with unix_socket_path
    std.debug.print("Connecting client to Unix socket: {s}...\n", .{socket_path});
    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withUnixSocket(socket_path));
    defer client.deinit();

    // Make an HTTP GET request over the Unix socket
    std.debug.print("Sending GET request over Unix socket...\n", .{});
    var resp = client.get("http://localhost/ipc-status", .{}) catch |err| {
        std.debug.print("Request failed: {s}\n", .{@errorName(err)});
        std.debug.print("=== Unix Domain Socket Example Skipped (request failed) ===\n", .{});
        return;
    };
    defer resp.deinit();

    // 4. Print results
    std.debug.print("\nResponse Status: {d}\n", .{resp.status.code});
    std.debug.print("Response Body:\n{s}\n", .{resp.text().?});

    std.debug.print("\n=== Unix Domain Socket Example Complete ===\n", .{});

    server.stop();
    thread.join();
}
