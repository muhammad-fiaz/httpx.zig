const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const candidates = [_][]const u8{
        "127.0.0.1",
        "::1",
        "192.168.1.1",
        "httpbun.com",
        "localhost",
        "10.0.0.1",
        "2001:db8::1",
    };
    for (candidates) |host| {
        std.debug.print("  {s: <22} isIP={}  isIPv4={}  isIPv6={}\n", .{
            host,
            httpx.isIpAddress(host),
            httpx.isIp4Address(host),
            httpx.isIp6Address(host),
        });
    }

    const host_ports = [_][]const u8{
        "127.0.0.1:8080",
        "[::1]:443",
        "httpbun.com:80",
    };
    for (host_ports) |hp| {
        const parsed = httpx.parseHostAndPort(hp, 0) catch null;
        if (parsed) |p| {
            std.debug.print("  {s} -> host=\"{s}\" port={d}\n", .{ hp, p.host, p.port });
        } else {
            std.debug.print("  {s} -> (parse failed)\n", .{hp});
        }
    }

    var resolver = httpx.DNSResolver.init(allocator, .{});
    defer resolver.deinit();

    var res = try resolver.resolve("127.0.0.1", .{ .port = 80 });
    defer res.deinit();
    std.debug.print("  resolve('127.0.0.1', port=80): {d} address(es)\n", .{res.addresses.len});

    var cached_resolver = httpx.DNSResolver.init(allocator, .{
        .positive_ttl_ms = 30_000,
        .negative_ttl_ms = 5_000,
        .max_cache_entries = 256,
    });
    defer cached_resolver.deinit();

    var r1 = try cached_resolver.resolve("127.0.0.1", .{ .port = 443 });
    defer r1.deinit();
    std.debug.print("  First resolve: {d} address(es)\n", .{r1.addresses.len});

    var r2 = try cached_resolver.resolve("127.0.0.1", .{ .port = 443 });
    defer r2.deinit();
    std.debug.print("  Second resolve (cached): {d} address(es)\n", .{r2.addresses.len});

    const stats = cached_resolver.getStats();
    std.debug.print("  Cache stats: hits={d} misses={d} literal_hits={d}\n", .{
        stats.hits,
        stats.misses,
        stats.literal_hits,
    });

    var v4_resolver = httpx.DNSResolver.init(allocator, .{
        .address_family = .ipv4_only,
    });
    defer v4_resolver.deinit();

    var v4_res = try v4_resolver.resolve("127.0.0.1", .{ .port = 80 });
    defer v4_res.deinit();
    std.debug.print("  ipv4_only resolve('127.0.0.1'): {d} address(es)\n", .{v4_res.addresses.len});

    std.debug.print("  Cache count before clear: {d}\n", .{cached_resolver.cache.count()});
    cached_resolver.clear();
    std.debug.print("  Cache count after clear: {d}\n", .{cached_resolver.cache.count()});
}
