//! Internet connectivity check example.
//!
//! Demonstrates all three API surfaces:
//!   1. Zero-config global:  httpx.isOnline()
//!   2. Detailed result:     httpx.checkConnectivity(.{})
//!   3. Client method:       client.isOnline() / client.checkConnectivity(.{})
//!
//! Run with: `zig build run-connectivity`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Zero-config global (no client, no allocator)
    std.debug.print("\n=== Zero-config check ===\n", .{});
    if (httpx.isOnline()) {
        std.debug.print("Internet is available.\n", .{});
    } else {
        std.debug.print("No internet connection detected.\n", .{});
    }

    // 2. Detailed result
    std.debug.print("\n=== Detailed connectivity probe ===\n", .{});
    const result = httpx.checkConnectivity(.{ .timeout_ms = 3000 });
    if (result.online) {
        const fam_str: []const u8 = if (result.family) |f| switch (f) {
            .ip4 => "IPv4",
            .ip6 => "IPv6",
        } else "?";
        std.debug.print(
            "Online: endpoint={s} family={s} latency={?d}ms\n",
            .{ result.endpointStr(), fam_str, result.latency_ms },
        );
    } else {
        std.debug.print("Offline: all probes failed.\n", .{});
    }

    // 3. Via an explicit Client
    std.debug.print("\n=== Via Client ===\n", .{});
    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const client_result = client.checkConnectivity(.{});
    if (client_result.online) {
        std.debug.print("Client: online via {s} ({?d}ms)\n", .{
            client_result.endpointStr(),
            client_result.latency_ms,
        });
    } else {
        std.debug.print("Client: offline.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}
