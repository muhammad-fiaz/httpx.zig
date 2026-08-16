//! Simple In-Memory DNS Cache & Resolver Wrapper for httpx.zig
//!
//! Provides a thread-safe DNS resolution cache with TTL tracking,
//! wrapping `std.net.getAddressList`.

const std = @import("std");
const net = @import("compat.zig");
const Allocator = std.mem.Allocator;
const address_mod = @import("address.zig");
const io_util = @import("../util/any_io.zig");
const threadIo = io_util.threadIo;

pub const DnsEntry = struct {
    address: net.Address,
    expires_at_ms: i64,
};

pub const DnsCache = struct {
    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(DnsEntry) = .{},
    lock: std.Io.Mutex = .init,
    default_ttl_ms: i64 = 60_000, // 60 seconds TTL

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        const io = threadIo();
        self.lock.lock(io) catch unreachable;
        defer self.lock.unlock(io);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *Self, host: []const u8, port: u16) !net.Address {
        const now_ms = @import("../util/common.zig").nowMillis();
        const io = threadIo();

        // 1. Check cache under lock
        {
            self.lock.lock(io) catch unreachable;
            if (self.entries.get(host)) |entry| {
                if (now_ms < entry.expires_at_ms) {
                    var addr = entry.address;
                    self.lock.unlock(io);
                    addr.setPort(port);
                    return addr;
                }
            }
            self.lock.unlock(io);
        }

        // 2. Cache miss — resolve without holding the lock
        const addr = try address_mod.resolve(self.allocator, host, port);

        // 3. Store in cache using getOrPut to avoid key leakage on refresh
        {
            self.lock.lock(io) catch unreachable;
            defer self.lock.unlock(io);

            const gop = try self.entries.getOrPut(self.allocator, host);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, host);
            }
            gop.value_ptr.* = .{
                .address = addr,
                .expires_at_ms = now_ms + self.default_ttl_ms,
            };
        }

        return addr;
    }

    /// Removes expired entries from the cache.
    /// Collects expired keys before removing to avoid skipping entries during iteration.
    pub fn prune(self: *Self) void {
        const now_ms = @import("../util/common.zig").nowMillis();
        const io = threadIo();
        self.lock.lock(io) catch unreachable;
        defer self.lock.unlock(io);

        var expired_keys = std.ArrayList([]const u8).empty;
        defer expired_keys.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (now_ms >= entry.value_ptr.expires_at_ms) {
                expired_keys.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (expired_keys.items) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }

    /// Clears all entries from the cache.
    pub fn clear(self: *Self) void {
        const io = threadIo();
        self.lock.lock(io) catch unreachable;
        defer self.lock.unlock(io);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Returns the number of cached DNS entries.
    pub fn count(self: *Self) usize {
        const io = threadIo();
        self.lock.lock(io) catch unreachable;
        defer self.lock.unlock(io);

        return self.entries.count();
    }
};
