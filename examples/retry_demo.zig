const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // Simple retry loop
    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        var response = client.get(.{ .url = "http://httpbun.com/get" }) catch |err| {
            std.debug.print("Attempt {d} failed: {s}\n", .{ attempts + 1, @errorName(err) });
            httpx.clock.sleepMillis(1000);
            continue;
        };
        defer response.deinit();
        std.debug.print("Status: {d}\n", .{response.status});
        return;
    }
    std.debug.print("All retries exhausted\n", .{});
}
