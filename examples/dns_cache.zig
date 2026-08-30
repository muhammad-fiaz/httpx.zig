const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{
        .dns_cache = .{
            .enabled = true,
            .ttl_ms = 60_000,
        },
    });
    defer client.deinit();

    // First request - DNS lookup + cache
    var r1 = try client.get(.{ .url = "http://httpbun.com/get" });
    defer r1.deinit();
    std.debug.print("R1 Status: {d}\n", .{r1.status});

    // Second request - uses cached DNS
    var r2 = try client.get(.{ .url = "http://httpbun.com/headers" });
    defer r2.deinit();
    std.debug.print("R2 Status: {d}\n", .{r2.status});
}
