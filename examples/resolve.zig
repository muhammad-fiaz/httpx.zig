const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize reusable client once
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 2. High-level DNS resolution using the client's cached resolver
    var addresses = client.resolve("httpbun.com", 443, .{}) catch |err| {
        std.debug.print("DNS lookup failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer addresses.deinit();

    // 3. User-friendly address iteration and native {f} formatting
    std.debug.print("Resolved {d} address(es) for httpbun.com:\n", .{addresses.len()});
    for (addresses.items) |addr| {
        std.debug.print("  {f}:{d} (family: {s})\n", .{ addr, addr.port, @tagName(addr.family) });
    }
}
