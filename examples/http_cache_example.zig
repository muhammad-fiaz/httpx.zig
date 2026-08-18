const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const headers = [_][]const u8{
        "max-age=3600, public",
        "no-store, no-cache",
        "s-maxage=7200, must-revalidate",
        "private, max-age=0",
        "immutable, max-age=31536000",
    };

    for (headers) |header| {
        const cc = httpx.CacheControl.parse(header);
        std.debug.print("  \"{s}\":\n", .{header});
        std.debug.print("    max-age={?}, public={}, no-store={}, must-revalidate={}\n", .{
            cc.max_age,
            cc.public,
            cc.no_store,
            cc.must_revalidate,
        });
    }

    var cache = httpx.HttpCache.init(allocator, 100, 1024 * 1024);
    defer cache.deinit();

    try cache.put(.{
        .key = "/api/users",
        .etag = "\"v1-abc123\"",
        .body = "[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]",
        .cache_control = .{ .max_age = 3600, .public = true },
    });

    try cache.put(.{
        .key = "/api/config",
        .body = "{\"theme\":\"dark\",\"lang\":\"en\"}",
        .cache_control = .{ .max_age = 86400, .immutable = true },
    });

    try cache.put(.{
        .key = "/api/session",
        .body = "{\"token\":\"secret\"}",
        .cache_control = .{ .private = true, .no_store = true },
    });

    if (cache.get("/api/users")) |entry| {
        std.debug.print("  Cache HIT for /api/users: {s}\n", .{entry.body});
        std.debug.print("  ETag: {s}\n", .{entry.etag orelse "none"});
    }

    const session = cache.get("/api/session");
    std.debug.print("  Cache for /api/session: {s}\n", .{if (session == null) "MISS (no-store)" else "HIT"});

    if (cache.get("/api/users")) |entry| {
        const cond = httpx.ConditionalGet.fromEntry(&entry);
        std.debug.print("  If-None-Match: {s}\n", .{cond.if_none_match orelse "none"});
        std.debug.print("  If-Modified-Since: {s}\n", .{cond.if_modified_since orelse "none"});
        std.debug.print("  304 means cache is still valid: {}\n", .{httpx.ConditionalGet.isNotModified(304)});
    }

    var small_cache = httpx.HttpCache.init(allocator, 3, 1024);
    defer small_cache.deinit();

    try small_cache.put(.{ .key = "/a", .body = "data-a", .cache_control = .{ .max_age = 3600 } });
    try small_cache.put(.{ .key = "/b", .body = "data-b", .cache_control = .{ .max_age = 3600 } });
    try small_cache.put(.{ .key = "/c", .body = "data-c", .cache_control = .{ .max_age = 3600 } });
    try small_cache.put(.{ .key = "/d", .body = "data-d", .cache_control = .{ .max_age = 3600 } });

    std.debug.print("  After inserting 4 entries into cache(max=3):\n", .{});
    std.debug.print("    /a: {s}\n", .{if (small_cache.get("/a") == null) "evicted" else "present"});
    std.debug.print("    /b: {s}\n", .{if (small_cache.get("/b") == null) "evicted" else "present"});
    std.debug.print("    /c: {s}\n", .{if (small_cache.get("/c") == null) "evicted" else "present"});
    std.debug.print("    /d: {s}\n", .{if (small_cache.get("/d") == null) "evicted" else "present"});

    _ = cache.invalidate("/api/users");
    std.debug.print("  Invalidated /api/users: {s}\n", .{if (cache.get("/api/users") == null) "gone" else "still present"});

    _ = cache.get("/api/config");
    _ = cache.get("/api/config");
    _ = cache.get("/nonexistent");

    const stats = cache.getStats();
    std.debug.print("  Hits: {d}\n", .{stats.hits});
    std.debug.print("  Misses: {d}\n", .{stats.misses});
    std.debug.print("  Hit rate: {d:.1}%\n", .{stats.hitRate() * 100.0});
}
