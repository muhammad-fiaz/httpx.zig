//! DNS Resolution Example
//!
//! Demonstrates DNS resolution helpers: resolveAddress, resolveAllAddresses,
//! parseHostAndPort, parseAndResolveAddress, isIpAddress, and the DnsCache.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== DNS Resolution Example ===\n\n", .{});

    // 1. IP address detection
    std.debug.print("--- IP Address Detection ---\n", .{});
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

    // 2. Parse host:port
    std.debug.print("\n--- Parse Host:Port ---\n", .{});
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

    // 3. Resolve hostname
    std.debug.print("\n--- Resolve Hostname ---\n", .{});
    const address = httpx.resolveAddress(allocator, "127.0.0.1", 80) catch |err| {
        std.debug.print("  resolveAddress failed: {}\n", .{err});
        return;
    };
    std.debug.print("  127.0.0.1:80 -> {any}\n", .{address});

    // 4. Resolve all addresses
    std.debug.print("\n--- Resolve All Addresses ---\n", .{});
    const all_addrs = httpx.resolveAllAddresses(allocator, "127.0.0.1", 443) catch |err| {
        std.debug.print("  resolveAllAddresses failed: {}\n", .{err});
        return;
    };
    defer allocator.free(all_addrs);
    std.debug.print("  127.0.0.1:443 -> {d} address(es)\n", .{all_addrs.len});

    // 5. Parse and resolve
    std.debug.print("\n--- Parse and Resolve ---\n", .{});
    const resolved = httpx.parseAndResolveAddress(allocator, "127.0.0.1", 8080) catch |err| {
        std.debug.print("  parseAndResolveAddress failed: {}\n", .{err});
        return;
    };
    std.debug.print("  127.0.0.1:8080 -> {any}\n", .{resolved});

    // 6. DNS Cache
    std.debug.print("\n--- DNS Cache ---\n", .{});
    var cache = httpx.dns.DnsCache.init(allocator);
    defer cache.deinit();

    const cached_addr = try cache.resolve("127.0.0.1", 80);
    std.debug.print("  First resolve: {any}\n", .{cached_addr});

    const cached_addr2 = try cache.resolve("127.0.0.1", 80);
    std.debug.print("  Second resolve (cached): {any}\n", .{cached_addr2});
    std.debug.print("  Cache hit: {}\n", .{std.mem.eql(u8, std.mem.asBytes(&cached_addr), std.mem.asBytes(&cached_addr2))});

    // 7. Convenience functions
    std.debug.print("\n--- Convenience Functions ---\n", .{});
    std.debug.print("  httpx.resolveAddress(host, port)      - single address\n", .{});
    std.debug.print("  httpx.resolveAllAddresses(alloc, host, port) - all candidates\n", .{});
    std.debug.print("  httpx.parseHostAndPort(str)           - parse \"host:port\"\n", .{});
    std.debug.print("  httpx.parseAndResolveAddress(host, port) - parse + resolve\n", .{});
    std.debug.print("  httpx.isIpAddress(str)               - IPv4/IPv6 check\n", .{});
    std.debug.print("  httpx.isIp4Address(str)              - IPv4 check\n", .{});
    std.debug.print("  httpx.isIp6Address(str)              - IPv6 check\n", .{});
    std.debug.print("  httpx.dns.DnsCache                   - TTL-based DNS cache\n", .{});

    std.debug.print("\n=== DNS Resolution Example Complete ===\n", .{});
}
