//! Internet connectivity check example.
//!
//! Demonstrates the high-level connectivity API and the client convenience
//! methods. Both reuse the `io` passed to `Client.init(allocator, io, .{})`.
//!
//! Run with: `zig build run-connectivity`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Explicit connectivity check with the documented default endpoints.
    std.debug.print("\n=== Connectivity check ===\n", .{});
    if (httpx.net.connectivity.isOnline(io)) {
        std.debug.print("Internet is available.\n", .{});
    } else {
        std.debug.print("No internet connection detected.\n", .{});
    }

    // 2. Detailed result from the high-level `check`.
    std.debug.print("\n=== Detailed connectivity check ===\n", .{});
    const result = httpx.net.connectivity.check(io, .{ .timeoutMs = 3000 });
    if (result.isOnline()) {
        printResult("Online", &result);
    } else {
        std.debug.print("Offline: all endpoints failed.\n", .{});
    }

    // 3. Via an explicit Client. The client owns the allocator and io; both
    //    checks reuse them instead of asking the caller to pass them again.
    //    `isOnline` is the boolean shorthand; `checkConnectivity` returns the
    //    detailed result.
    std.debug.print("\n=== Via Client ===\n", .{});
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    if (client.isOnline(.{})) {
        std.debug.print("Client: online.\n", .{});
    } else {
        std.debug.print("Client: offline.\n", .{});
    }

    const clientResult = client.checkConnectivity(.{});
    if (clientResult.isOnline()) {
        printResult("Client detail", &clientResult);
    } else {
        std.debug.print("Client detail: offline.\n", .{});
    }

    // 4. Check endpoints you control. This is the high-level form: textual IP
    //    endpoints with an explicit port, no internal address types needed.
    std.debug.print("\n=== Custom endpoints ===\n", .{});
    const customResult = client.checkHosts(&.{ "1.1.1.1:53", "[2606:4700:4700::1111]:53" }, .{ .timeoutMs = 2000 });
    if (customResult.isOnline()) {
        printResult("Custom: online", &customResult);
    } else {
        std.debug.print("Custom: offline.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}

fn printResult(label: []const u8, result: *const httpx.net.connectivity.ConnectivityResult) void {
    const family: []const u8 = if (result.family) |f| switch (f) {
        .ip4 => "IPv4",
        .ip6 => "IPv6",
    } else "?";
    std.debug.print("{s}: endpoint={s} family={s} latency={?d}ms\n", .{
        label,
        result.endpointStr(),
        family,
        result.latencyMs,
    });
}
