const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // DNS resolution
    const addrs = try httpx.resolve.Resolver.init(allocator).lookup("httpbun.com", 443);
    defer allocator.free(addrs);

    var buf: [64]u8 = undefined;
    for (addrs) |addr| {
        const ip = addr.format(&buf);
        std.debug.print("Resolved: {s}:{d}\n", .{ ip, addr.port });
    }
}
