//! DNS Configuration Example
//!
//! Demonstrates configuring the DNSResolver with various options:
//! TTL settings, cache bounds, address family/ordering, dedup, and
//! integration with the HTTP client.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== DNS Configuration Example ===\n\n", .{});

    // 1. Default configuration
    std.debug.print("--- Default Config ---\n", .{});
    var default_resolver = httpx.DNSResolver.init(allocator, .{});
    defer default_resolver.deinit();
    std.debug.print("  positive_ttl_ms: 60000\n", .{});
    std.debug.print("  negative_ttl_ms: 5000\n", .{});
    std.debug.print("  max_cache_entries: 1024\n", .{});
    std.debug.print("  cache_enabled: true\n", .{});
    std.debug.print("  dedup_enabled: true\n", .{});

    // 2. Custom TTL configuration
    std.debug.print("\n--- Custom TTL Config ---\n", .{});
    var short_ttl = httpx.DNSResolver.init(allocator, .{
        .positive_ttl_ms = 5_000,
        .negative_ttl_ms = 1_000,
    });
    defer short_ttl.deinit();
    std.debug.print("  Short TTL resolver created (5s positive, 1s negative)\n", .{});

    // 3. Bounded cache (LRU eviction)
    std.debug.print("\n--- Bounded Cache (LRU) ---\n", .{});
    var bounded = httpx.DNSResolver.init(allocator, .{
        .max_cache_entries = 64,
    });
    defer bounded.deinit();
    std.debug.print("  Bounded cache resolver created (max 64 entries)\n", .{});

    // 4. IPv4-only resolution
    std.debug.print("\n--- IPv4 Only ---\n", .{});
    var ipv4_only = httpx.DNSResolver.init(allocator, .{
        .address_family = .ipv4_only,
    });
    defer ipv4_only.deinit();
    var v4_res = try ipv4_only.resolve("127.0.0.1", .{ .port = 80 });
    defer v4_res.deinit();
    std.debug.print("  ipv4_only resolve('127.0.0.1'): {d} address(es)\n", .{v4_res.addresses.len});

    // 5. IPv6-preferred ordering
    std.debug.print("\n--- IPv6 Preferred ---\n", .{});
    var ipv6_pref = httpx.DNSResolver.init(allocator, .{
        .address_order = .ipv6_preferred,
    });
    defer ipv6_pref.deinit();
    std.debug.print("  IPv6-preferred ordering configured\n", .{});

    // 6. Cache-only mode (no DNS lookups)
    std.debug.print("\n--- Cache-Only Mode ---\n", .{});
    var cache_only = httpx.DNSResolver.init(allocator, .{
        .cache_enabled = true,
        .dedup_enabled = false,
    });
    defer cache_only.deinit();
    std.debug.print("  Cache-only resolver created (dedup disabled)\n", .{});

    // 7. Client integration
    std.debug.print("\n--- Client Integration ---\n", .{});
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

    std.debug.print("\n=== DNS Configuration Example Complete ===\n", .{});
}
