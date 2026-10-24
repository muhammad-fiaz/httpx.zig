//! Internet connectivity check example.
//!
//! Demonstrates explicit connectivity probes and the client convenience API.
//!
//! Run with: `zig build run-connectivity`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Explicit I/O probe
    std.debug.print("\n=== Connectivity check ===\n", .{});
    if (httpx.net.connectivity.isOnline(io)) {
        std.debug.print("Internet is available.\n", .{});
    } else {
        std.debug.print("No internet connection detected.\n", .{});
    }

    // 2. Detailed result
    std.debug.print("\n=== Detailed connectivity probe ===\n", .{});
    const result = httpx.net.connectivity.checkConnectivity(io, .{ .timeoutMs = 3000 });
    if (result.online) {
        const famStr: []const u8 = if (result.family) |f| switch (f) {
            .ip4 => "IPv4",
            .ip6 => "IPv6",
        } else "?";
        std.debug.print(
            "Online: endpoint={s} family={s} latency={?d}ms\n",
            .{ result.endpointStr(), famStr, result.latencyMs },
        );
    } else {
        std.debug.print("Offline: all probes failed.\n", .{});
    }

    // 3. Via an explicit Client
    std.debug.print("\n=== Via Client ===\n", .{});
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const clientResult = client.checkConnectivity(.{});
    if (clientResult.online) {
        std.debug.print("Client: online via {s} ({?d}ms)\n", .{
            clientResult.endpointStr(),
            clientResult.latencyMs,
        });
    } else {
        std.debug.print("Client: offline.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}
