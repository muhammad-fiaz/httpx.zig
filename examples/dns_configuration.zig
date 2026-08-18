const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var default_resolver = httpx.DNSResolver.init(allocator, .{});
    defer default_resolver.deinit();

    var short_ttl = httpx.DNSResolver.init(allocator, .{
        .positive_ttl_ms = 5_000,
        .negative_ttl_ms = 1_000,
    });
    defer short_ttl.deinit();
    std.debug.print("  Short TTL resolver created (5s positive, 1s negative)\n", .{});

    var bounded = httpx.DNSResolver.init(allocator, .{
        .max_cache_entries = 64,
    });
    defer bounded.deinit();
    std.debug.print("  Bounded cache resolver created (max 64 entries)\n", .{});

    var ipv4_only = httpx.DNSResolver.init(allocator, .{
        .address_family = .ipv4_only,
    });
    defer ipv4_only.deinit();
    var v4_res = try ipv4_only.resolve("127.0.0.1", .{ .port = 80 });
    defer v4_res.deinit();
    std.debug.print("  ipv4_only resolve('127.0.0.1'): {d} address(es)\n", .{v4_res.addresses.len});

    var ipv6_pref = httpx.DNSResolver.init(allocator, .{
        .address_order = .ipv6_preferred,
    });
    defer ipv6_pref.deinit();
    std.debug.print("  IPv6-preferred ordering configured\n", .{});

    var cache_only = httpx.DNSResolver.init(allocator, .{
        .cache_enabled = true,
        .dedup_enabled = false,
    });
    defer cache_only.deinit();
    std.debug.print("  Cache-only resolver created (dedup disabled)\n", .{});

    var client_resolver = httpx.DNSResolver.init(allocator, .{
        .positive_ttl_ms = 30_000,
        .max_cache_entries = 512,
    });
    defer client_resolver.deinit();

    var client = httpx.Client.initWithConfig(allocator, .{
        .dns_resolver = &client_resolver,
    });
    defer client.deinit();
    std.debug.print("  Client configured with DNS resolver\n", .{});
    std.debug.print("  All requests will use cached DNS resolution\n", .{});
}
