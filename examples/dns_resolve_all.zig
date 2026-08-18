const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resolver = httpx.DNSResolver.init(allocator, .{});
    defer resolver.deinit();

    var res = try resolver.resolveAll("127.0.0.1", .{ .port = 8080 });
    defer res.deinit();
    std.debug.print("  127.0.0.1 -> {d} address(es)\n", .{res.addresses.len});
    for (res.addresses) |addr| {
        std.debug.print("    {any}\n", .{addr});
    }

    var res6 = try resolver.resolveAll("::1", .{ .port = 443 });
    defer res6.deinit();
    std.debug.print("  ::1 -> {d} address(es)\n", .{res6.addresses.len});

    var r_single = try resolver.resolve("10.0.0.1", .{ .port = 80 });
    defer r_single.deinit();
    std.debug.print("  resolve('10.0.0.1'): {d} address(es)\n", .{r_single.addresses.len});

    var r_all = try resolver.resolveAll("10.0.0.1", .{ .port = 80 });
    defer r_all.deinit();
    std.debug.print("  resolveAll('10.0.0.1'): {d} address(es)\n", .{r_all.addresses.len});

    const targets = [_][]const u8{ "127.0.0.1", "::1", "192.168.1.1" };
    for (targets) |host| {
        var r = try resolver.resolveAll(host, .{ .port = 80 });
        defer r.deinit();
        std.debug.print("  {s}: {d} address(es)\n", .{ host, r.addresses.len });
    }
}
