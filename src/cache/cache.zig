//! HTTP Caching Layer for httpx.zig
//!
//! Provides Cache-Control header parsing, an in-memory LRU cache with TTL
//! expiration, and conditional GET support (If-None-Match / If-Modified-Since).
//!
//! References: RFC 7234 (HTTP Caching), RFC 7232 (Conditional Requests).

const std = @import("std");
const Allocator = std.mem.Allocator;
const io_util = @import("../io/any_io.zig");

/// Parsed Cache-Control directives from a header value.
pub const CacheControl = struct {
    no_store: bool = false,
    no_cache: bool = false,
    must_revalidate: bool = false,
    proxy_revalidate: bool = false,
    max_age: ?u64 = null,
    s_maxage: ?u64 = null,
    max_stale: ?u64 = null,
    min_fresh: ?u64 = null,
    only_if_cached: bool = false,
    public: bool = false,
    private: bool = false,
    immutable: bool = false,

    /// Parse a Cache-Control header value into directives.
    pub fn parse(header_value: []const u8) CacheControl {
        var result = CacheControl{};
        var iter = std.mem.splitScalar(u8, header_value, ',');
        while (iter.next()) |token_raw| {
            const token = std.mem.trim(u8, token_raw, " \t");
            if (token.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(token, "no-store")) {
                result.no_store = true;
            } else if (std.ascii.eqlIgnoreCase(token, "no-cache")) {
                result.no_cache = true;
            } else if (std.ascii.eqlIgnoreCase(token, "must-revalidate")) {
                result.must_revalidate = true;
            } else if (std.ascii.eqlIgnoreCase(token, "proxy-revalidate")) {
                result.proxy_revalidate = true;
            } else if (std.ascii.eqlIgnoreCase(token, "public")) {
                result.public = true;
            } else if (std.ascii.eqlIgnoreCase(token, "private")) {
                result.private = true;
            } else if (std.ascii.eqlIgnoreCase(token, "immutable")) {
                result.immutable = true;
            } else if (std.ascii.eqlIgnoreCase(token, "only-if-cached")) {
                result.only_if_cached = true;
            } else if (std.mem.startsWith(u8, token, "max-age=")) {
                result.max_age = std.fmt.parseInt(u64, token[8..], 10) catch null;
            } else if (std.mem.startsWith(u8, token, "s-maxage=")) {
                result.s_maxage = std.fmt.parseInt(u64, token[9..], 10) catch null;
            } else if (std.mem.startsWith(u8, token, "max-stale=")) {
                result.max_stale = std.fmt.parseInt(u64, token[10..], 10) catch null;
            } else if (std.mem.startsWith(u8, token, "min-fresh=")) {
                result.min_fresh = std.fmt.parseInt(u64, token[10..], 10) catch null;
            }
        }
        return result;
    }

    /// Determine the effective max-age (prefers s-maxage for shared caches).
    pub fn effectiveMaxAge(self: *const CacheControl) ?u64 {
        return self.s_maxage orelse self.max_age;
    }
};

/// Parse an Expires header value into a timestamp (seconds since epoch).
/// Returns null if the header cannot be parsed.
pub fn parseExpires(header_value: []const u8) ?i64 {
    // Try RFC 1123 date format: "Sun, 06 Nov 1994 08:49:37 GMT"
    // For simplicity, we parse the date components manually.
    const trimmed = std.mem.trim(u8, header_value, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Simple check: if it ends with "GMT", try to parse.
    if (!std.mem.endsWith(u8, trimmed, "GMT")) return null;

    // Parse: "Day, DD Mon YYYY HH:MM:SS GMT"
    // We need at least 29 characters: "Sun, 06 Nov 1994 08:49:37 GMT"
    if (trimmed.len < 29) return null;

    // Skip day name and comma: position 5
    // Parse DD at positions 5-6
    const day = std.fmt.parseInt(u32, trimmed[5..7], 10) catch return null;

    // Parse month at positions 8-10
    const month_str = trimmed[8..11];
    const month: u32 = if (std.ascii.eqlIgnoreCase(month_str, "jan")) 1 //
        else if (std.ascii.eqlIgnoreCase(month_str, "feb")) 2 //
        else if (std.ascii.eqlIgnoreCase(month_str, "mar")) 3 //
        else if (std.ascii.eqlIgnoreCase(month_str, "apr")) 4 //
        else if (std.ascii.eqlIgnoreCase(month_str, "may")) 5 //
        else if (std.ascii.eqlIgnoreCase(month_str, "jun")) 6 //
        else if (std.ascii.eqlIgnoreCase(month_str, "jul")) 7 //
        else if (std.ascii.eqlIgnoreCase(month_str, "aug")) 8 //
        else if (std.ascii.eqlIgnoreCase(month_str, "sep")) 9 //
        else if (std.ascii.eqlIgnoreCase(month_str, "oct")) 10 //
        else if (std.ascii.eqlIgnoreCase(month_str, "nov")) 11 //
        else if (std.ascii.eqlIgnoreCase(month_str, "dec")) 12 //
        else return null;

    // Parse year at positions 12-15
    const year = std.fmt.parseInt(u32, trimmed[12..16], 10) catch return null;

    // Parse hour at positions 17-18
    const hour = std.fmt.parseInt(u32, trimmed[17..19], 10) catch return null;

    // Parse minute at positions 20-21
    const minute = std.fmt.parseInt(u32, trimmed[20..22], 10) catch return null;

    // Parse second at positions 23-24
    const second = std.fmt.parseInt(u32, trimmed[23..25], 10) catch return null;

    // Convert to seconds since epoch (simplified - no timezone conversion needed for GMT).
    var total_days: i64 = 0;

    // Days from complete years (year 1970 to year-1 inclusive)
    const y = @as(i64, year) - 1970;
    total_days += y * 365;
    // Add leap year days for [1970, year) range
    // countLeapYears(Y) = Y/4 - Y/100 + Y/400 counts leap years from year 1 to Y
    // We need countLeapYears(year-1) - countLeapYears(1970)
    total_days += @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);

    // Days from months in current year
    const leap = (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0));
    const days_in_month = [_]u32{ 31, if (leap) @as(u32, 29) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u32 = 0;
    while (m < month - 1) : (m += 1) {
        total_days += days_in_month[m];
    }
    total_days += @intCast(day - 1);

    const total_seconds = total_days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return total_seconds;
}

/// Parse an Age header value (integer seconds).
pub fn parseAge(header_value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, header_value, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

/// A single entry in the cache.
pub const CacheEntry = struct {
    key: []const u8,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    max_age: u64 = 0,
    stored_at: i64 = 0,
    age: u64 = 0,
    body: []const u8,
    status_code: u16 = 200,
    content_type: ?[]const u8 = null,
    cache_control: CacheControl = .{},
    vary: ?[]const u8 = null,

    /// Check if this entry has expired based on the current time.
    pub fn isExpired(self: *const CacheEntry, now_seconds: i64) bool {
        if (self.cache_control.no_store) return true;
        const elapsed = @as(u64, @intCast(@max(0, now_seconds - self.stored_at)));
        const effective_age = elapsed +| self.age;
        return effective_age > self.max_age;
    }

    /// Check if this entry can be served without revalidation.
    pub fn isFresh(self: *const CacheEntry, now_seconds: i64) bool {
        if (self.cache_control.no_cache) return false;
        if (self.cache_control.must_revalidate) return false;
        if (self.max_age == 0) return false;
        return !self.isExpired(now_seconds);
    }
};

/// Cache statistics for metrics integration.
pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    revalidations: u64 = 0,
    evictions: u64 = 0,
    insertions: u64 = 0,

    pub fn hitRate(self: *const CacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// An in-memory LRU cache with TTL expiration and thread safety.
pub const HttpCache = struct {
    allocator: Allocator,
    entries: std.ArrayList(CacheEntry),
    max_entries: usize,
    total_size: usize,
    max_size: usize,
    mutex: std.Io.Mutex = .init,
    stats: CacheStats = .{},

    fn lock(self: *HttpCache) void {
        const io = io_util.defaultIo();
        self.mutex.lock(io) catch unreachable;
    }

    fn unlock(self: *HttpCache) void {
        const io = io_util.defaultIo();
        self.mutex.unlock(io);
    }

    pub fn init(allocator: Allocator, max_entries: usize, max_size: usize) HttpCache {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .max_entries = max_entries,
            .total_size = 0,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *HttpCache) void {
        self.lock();
        defer self.unlock();

        self.freeAllEntries();
        self.entries.deinit(self.allocator);
    }

    fn freeEntry(self: *HttpCache, entry: *const CacheEntry) void {
        self.allocator.free(entry.key);
        if (entry.etag) |e| self.allocator.free(e);
        if (entry.last_modified) |lm| self.allocator.free(lm);
        self.allocator.free(entry.body);
        if (entry.content_type) |ct| self.allocator.free(ct);
        if (entry.vary) |v| self.allocator.free(v);
    }

    fn freeAllEntries(self: *HttpCache) void {
        for (self.entries.items) |*entry| {
            self.freeEntry(entry);
        }
        self.entries.clearRetainingCapacity();
        self.total_size = 0;
    }

    /// Look up a cached response by key. Thread-safe.
    pub fn get(self: *HttpCache, key: []const u8) ?CacheEntry {
        self.lock();
        defer self.unlock();

        const now = std.Io.Timestamp.now(io_util.defaultIo(), .real).toSeconds();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (std.mem.eql(u8, entry.key, key)) {
                if (entry.isExpired(now)) {
                    self.stats.misses += 1;
                    return null;
                }
                self.stats.hits += 1;
                const entry_copy = entry;
                _ = self.entries.orderedRemove(i);
                self.entries.append(self.allocator, entry_copy) catch return entry_copy;
                return entry_copy;
            }
            i += 1;
        }
        self.stats.misses += 1;
        return null;
    }

    /// Insert or update a cache entry. Thread-safe.
    pub fn put(self: *HttpCache, entry: CacheEntry) !void {
        self.lock();
        defer self.unlock();

        if (entry.cache_control.no_store) return;

        const max_age = entry.cache_control.effectiveMaxAge() orelse 0;
        if (max_age == 0) return;

        var new_entry = entry;
        new_entry.max_age = max_age;
        new_entry.stored_at = std.Io.Timestamp.now(io_util.defaultIo(), .real).toSeconds();

        // Evict LRU if at capacity.
        while (self.entries.items.len >= self.max_entries or
            self.total_size + entry.body.len > self.max_size)
        {
            if (self.entries.items.len == 0) break;
            const evicted = self.entries.orderedRemove(0);
            self.total_size -|= evicted.body.len;
            self.freeEntry(&evicted);
            self.stats.evictions += 1;
        }

        new_entry.key = try self.allocator.dupe(u8, entry.key);
        new_entry.body = try self.allocator.dupe(u8, entry.body);
        if (entry.etag) |e| new_entry.etag = try self.allocator.dupe(u8, e);
        if (entry.last_modified) |lm| new_entry.last_modified = try self.allocator.dupe(u8, lm);
        if (entry.content_type) |ct| new_entry.content_type = try self.allocator.dupe(u8, ct);
        if (entry.vary) |v| new_entry.vary = try self.allocator.dupe(u8, v);

        self.total_size += new_entry.body.len;
        try self.entries.append(self.allocator, new_entry);
        self.stats.insertions += 1;
    }

    /// Remove all expired entries. Thread-safe.
    pub fn prune(self: *HttpCache) void {
        self.lock();
        defer self.unlock();

        const now = std.Io.Timestamp.now(io_util.defaultIo(), .real).toSeconds();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].isExpired(now)) {
                const evicted = self.entries.orderedRemove(i);
                self.total_size -|= evicted.body.len;
                self.freeEntry(&evicted);
                self.stats.evictions += 1;
            } else {
                i += 1;
            }
        }
    }

    /// Clear all entries. Thread-safe.
    pub fn clear(self: *HttpCache) void {
        self.lock();
        defer self.unlock();

        self.freeAllEntries();
    }

    /// Invalidate a specific cache entry by key. Thread-safe.
    pub fn invalidate(self: *HttpCache, key: []const u8) bool {
        self.lock();
        defer self.unlock();

        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.key, key)) {
                const evicted = self.entries.orderedRemove(i);
                self.total_size -|= evicted.body.len;
                self.freeEntry(&evicted);
                return true;
            }
        }
        return false;
    }

    /// Get a snapshot of the cache statistics.
    pub fn getStats(self: *const HttpCache) CacheStats {
        return self.stats;
    }

    pub fn count(self: *HttpCache) usize {
        self.lock();
        defer self.unlock();
        return self.entries.items.len;
    }
};

/// Helper to build conditional GET headers from a cached entry.
pub const ConditionalGet = struct {
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,

    /// Build conditional headers from a cached entry.
    pub fn fromEntry(entry: *const CacheEntry) ConditionalGet {
        return .{
            .if_none_match = entry.etag,
            .if_modified_since = entry.last_modified,
        };
    }

    /// Check if a 304 Not Modified response means the cache is still valid.
    pub fn isNotModified(status_code: u16) bool {
        return status_code == 304;
    }
};

test "cache-control parse no-store" {
    const cc = CacheControl.parse("no-store");
    try std.testing.expect(cc.no_store);
    try std.testing.expect(!cc.no_cache);
}

test "cache-control parse max-age" {
    const cc = CacheControl.parse("max-age=3600, public");
    try std.testing.expectEqual(@as(?u64, 3600), cc.max_age);
    try std.testing.expect(cc.public);
}

test "cache-control parse s-maxage" {
    const cc = CacheControl.parse("s-maxage=7200, max-age=3600");
    try std.testing.expectEqual(@as(?u64, 7200), cc.s_maxage);
    try std.testing.expectEqual(@as(?u64, 3600), cc.max_age);
    try std.testing.expectEqual(@as(?u64, 7200), cc.effectiveMaxAge());
}

test "cache put and get" {
    const allocator = std.testing.allocator;
    var cache = HttpCache.init(allocator, 10, 1024 * 1024);
    defer cache.deinit();

    try cache.put(.{
        .key = "/api/data",
        .etag = "\"abc123\"",
        .body = "{\"ok\":true}",
        .cache_control = .{ .max_age = 3600 },
    });

    const entry = cache.get("/api/data");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("\"abc123\"", entry.?.etag.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", entry.?.body);

    try std.testing.expect(cache.get("/nonexistent") == null);
}

test "cache eviction" {
    const allocator = std.testing.allocator;
    var cache = HttpCache.init(allocator, 2, 1024);
    defer cache.deinit();

    try cache.put(.{ .key = "/a", .body = "aaa", .cache_control = .{ .max_age = 3600 } });
    try cache.put(.{ .key = "/b", .body = "bbb", .cache_control = .{ .max_age = 3600 } });
    try cache.put(.{ .key = "/c", .body = "ccc", .cache_control = .{ .max_age = 3600 } });

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get("/a") == null);
    try std.testing.expect(cache.get("/b") != null);
    try std.testing.expect(cache.get("/c") != null);
}

test "cache no-store is not stored" {
    const allocator = std.testing.allocator;
    var cache = HttpCache.init(allocator, 10, 1024);
    defer cache.deinit();

    try cache.put(.{
        .key = "/sensitive",
        .body = "secret",
        .cache_control = .{ .no_store = true },
    });

    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "cache invalidate" {
    const allocator = std.testing.allocator;
    var cache = HttpCache.init(allocator, 10, 1024);
    defer cache.deinit();

    try cache.put(.{ .key = "/to-remove", .body = "data", .cache_control = .{ .max_age = 3600 } });
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    const removed = cache.invalidate("/to-remove");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    const not_removed = cache.invalidate("/nonexistent");
    try std.testing.expect(!not_removed);
}

test "cache statistics" {
    const allocator = std.testing.allocator;
    var cache = HttpCache.init(allocator, 10, 1024);
    defer cache.deinit();

    try cache.put(.{ .key = "/a", .body = "data", .cache_control = .{ .max_age = 3600 } });

    _ = cache.get("/a");
    _ = cache.get("/b");

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}

test "parse expires header" {
    const ts = parseExpires("Sun, 06 Nov 1994 08:49:37 GMT");
    try std.testing.expect(ts != null);
    try std.testing.expect(ts.? > 0);
}

test "parse expires leap year correctness" {
    // 2000-03-01 00:00:00 GMT (2000 is a leap year)
    // Epoch for 2000-01-01 is 946684800
    // Days in Jan: 31, Feb: 29 (leap year), so Mar 1 is 31+29=60 days after Jan 1
    // 60 days = 60 * 86400 = 5184000
    // Expected: 946684800 + 5184000 = 951868800
    const ts = parseExpires("Wed, 01 Mar 2000 00:00:00 GMT");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 951868800), ts.?);

    // 1996-03-01 00:00:00 GMT (1996 is a leap year)
    // Epoch for 1996-01-01 is 820454400
    // Days in Jan: 31, Feb: 29 (leap year), so Mar 1 is 60 days after Jan 1
    // 60 days = 5184000
    // Expected: 820454400 + 5184000 = 825638400
    const ts2 = parseExpires("Fri, 01 Mar 1996 00:00:00 GMT");
    try std.testing.expect(ts2 != null);
    try std.testing.expectEqual(@as(i64, 825638400), ts2.?);
}

test "parse age header" {
    const age = parseAge("120");
    try std.testing.expectEqual(@as(?u64, 120), age);
}
