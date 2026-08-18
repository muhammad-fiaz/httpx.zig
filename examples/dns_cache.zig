const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cache = httpx.DNSCache.init(allocator, .{
        .positive_ttl_ms = 10_000,
        .negative_ttl_ms = 5_000,
        .max_cache_entries = 10,
    });
    defer cache.deinit();

    std.debug.print("  Cache count: {d}\n", .{cache.count()});

    const stats = cache.getStats();
    std.debug.print("  Hits: {d}\n", .{stats.hits});
    std.debug.print("  Misses: {d}\n", .{stats.misses});
    std.debug.print("  Failures: {d}\n", .{stats.failures});
    std.debug.print("  Evictions: {d}\n", .{stats.evictions});
    std.debug.print("  Hit rate: {d:.1}%\n", .{stats.hitRate() * 100});

    cache.invalidate("example.com");
    std.debug.print("  Invalidated 'example.com'\n", .{});

    cache.clear();
    std.debug.print("  Cache cleared. Count: {d}\n", .{cache.count()});

    cache.evictExpired();
    std.debug.print("  Expired entries evicted.\n", .{});
}
