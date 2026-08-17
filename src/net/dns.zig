//! In-Memory DNS Cache & Resolver Wrapper for httpx.zig
//!
//! Provides a thread-safe DNS resolution cache with TTL tracking,
//! automatic expiry eviction, negative caching, and observability stats.
//! Wraps `std.net.getAddressList` for actual resolution.

const std = @import("std");
const net = @import("compat.zig");
const Allocator = std.mem.Allocator;
const address_mod = @import("address.zig");
const io_util = @import("../util/any_io.zig");
const threadIo = io_util.threadIo;
const dbg = @import("../util/debug.zig");

pub const DnsEntry = struct {
    address: net.Address,
    expires_at_ms: i64,
    /// Whether this entry represents a failed resolution (negative cache).
    failed: bool = false,
};

pub const DnsStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    failures: u64 = 0,
    evictions: u64 = 0,

    pub fn hitRate(self: DnsStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

pub const DnsCache = struct {
    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(DnsEntry) = .{},
    lock: std.Io.Mutex = .init,
    default_ttl_ms: i64 = 60_000,
    /// TTL for failed resolutions (negative cache). Shorter than positive TTL.
    negative_ttl_ms: i64 = 5_000,
    /// Maximum number of cached entries. 0 = unlimited.
    max_entries: u32 = 0,
    stats: DnsStats = .{},

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    /// Resolves a hostname to an address, using the cache when the entry is
    /// still valid. On cache miss, performs a system DNS lookup and stores
    /// the result. Failed lookups are cached briefly to avoid hammering DNS.
    pub fn resolve(self: *Self, host: []const u8, port: u16) !net.Address {
        dbg.entry("DNS", "DnsCache.resolve");
        const now_ms = @import("../util/common.zig").nowMillis();

        {
            self.lock.lock(threadIo()) catch unreachable;
            defer self.lock.unlock(threadIo());

            if (self.entries.get(host)) |entry| {
                if (now_ms < entry.expires_at_ms) {
                    self.stats.hits += 1;
                    dbg.log("DNS", "cache hit for {s}:{d}", .{ host, port });
                    if (entry.failed) {
                        dbg.exitErr("DNS", "DnsCache.resolve", error.DnsLookupFailed);
                        return error.DnsLookupFailed;
                    }
                    var addr = entry.address;
                    addr.setPort(port);
                    dbg.exit("DNS", "DnsCache.resolve");
                    return addr;
                }
                self.removeEntry(host);
            }
            self.stats.misses += 1;
            dbg.log("DNS", "cache miss for {s}:{d}", .{ host, port });
        }

        const addr = address_mod.resolve(self.allocator, host, port) catch |err| {
            self.cacheFailure(host, now_ms);
            self.stats.failures += 1;
            dbg.logErr("DNS", "DnsCache.resolve", err);
            dbg.exitErr("DNS", "DnsCache.resolve", err);
            return err;
        };

        self.cacheSuccess(host, addr, now_ms);
        dbg.exit("DNS", "DnsCache.resolve");
        return addr;
    }

    /// Evicts all expired entries from the cache.
    pub fn evictExpired(self: *Self) void {
        const now_ms = @import("../util/common.zig").nowMillis();

        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (now_ms >= entry.value_ptr.expires_at_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            self.removeEntry(key);
            self.stats.evictions += 1;
        }
    }

    /// Returns the number of cached entries.
    pub fn count(self: *Self) u32 {
        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());
        return @intCast(self.entries.count());
    }

    /// Clears all cached entries.
    pub fn clear(self: *Self) void {
        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Returns a snapshot of cache statistics.
    pub fn getStats(self: *Self) DnsStats {
        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());
        return self.stats;
    }

    fn cacheSuccess(self: *Self, host: []const u8, addr: net.Address, now_ms: i64) void {
        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());

        self.evictIfNeeded();

        const key = self.allocator.dupe(u8, host) catch return;
        self.entries.put(self.allocator, key, .{
            .address = addr,
            .expires_at_ms = now_ms + self.default_ttl_ms,
        }) catch {
            self.allocator.free(key);
        };
    }

    fn cacheFailure(self: *Self, host: []const u8, now_ms: i64) void {
        self.lock.lock(threadIo()) catch unreachable;
        defer self.lock.unlock(threadIo());

        self.evictIfNeeded();

        const key = self.allocator.dupe(u8, host) catch return;
        self.entries.put(self.allocator, key, .{
            .address = std.mem.zeroes(net.Address),
            .expires_at_ms = now_ms + self.negative_ttl_ms,
            .failed = true,
        }) catch {
            self.allocator.free(key);
        };
    }

    fn evictIfNeeded(self: *Self) void {
        if (self.max_entries == 0) return;
        while (self.entries.count() >= self.max_entries) {
            // Evict oldest entry (first found)
            var it = self.entries.iterator();
            if (it.next()) |oldest| {
                const key = self.allocator.dupe(u8, oldest.key_ptr.*) catch return;
                self.removeEntry(key);
                self.allocator.free(key);
                self.stats.evictions += 1;
            } else break;
        }
    }

    fn removeEntry(self: *Self, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }
};
