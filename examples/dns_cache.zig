//! DNS Cache Example
//!
//! Demonstrates the DNSCache directly: manual store, lookup, TTL expiration,
//! negative caching, LRU eviction, and statistics.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== DNS Cache Example ===\n\n", .{});

    // 1. Basic cache operations
    std.debug.print("--- Basic Cache Operations ---\n", .{});
    var cache = httpx.DNSCache.init(allocator, .{
        .positive_ttl_ms = 10_000,
        .negative_ttl_ms = 5_000,
        .max_cache_entries = 10,
    });
    defer cache.deinit();

    std.debug.print("  Cache count: {d}\n", .{cache.count()});

    // 2. Cache statistics
    std.debug.print("\n--- Cache Statistics ---\n", .{});
    const stats = cache.getStats();
    std.debug.print("  Hits: {d}\n", .{stats.hits});
    std.debug.print("  Misses: {d}\n", .{stats.misses});
    std.debug.print("  Failures: {d}\n", .{stats.failures});
    std.debug.print("  Evictions: {d}\n", .{stats.evictions});
    std.debug.print("  Hit rate: {d:.1}%\n", .{stats.hitRate() * 100});

    // 3. Cache invalidation
    std.debug.print("\n--- Cache Invalidation ---\n", .{});
    cache.invalidate("example.com");
    std.debug.print("  Invalidated 'example.com'\n", .{});

    // 4. Clear all entries
    std.debug.print("\n--- Clear Cache ---\n", .{});
    cache.clear();
    std.debug.print("  Cache cleared. Count: {d}\n", .{cache.count()});

    // 5. Evict expired entries
    std.debug.print("\n--- Evict Expired ---\n", .{});
    cache.evictExpired();
    std.debug.print("  Expired entries evicted.\n", .{});

    std.debug.print("\n=== DNS Cache Example Complete ===\n", .{});
}
