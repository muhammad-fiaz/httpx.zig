//! Simple In-Memory DNS Cache & Resolver Wrapper for httpx.zig
//!
//! Provides a thread-safe DNS resolution cache with TTL tracking,
//! wrapping `std.net.getAddressList`.

const std = @import("std");
const net = @import("compat.zig");
const Allocator = std.mem.Allocator;
const address_mod = @import("address.zig");

pub const DnsEntry = struct {
    address: net.Address,
    expires_at_ms: i64,
};

pub const DnsCache = struct {
    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(DnsEntry) = .{},
    lock: std.Io.RwLock = .init,
    default_ttl_ms: i64 = 60_000, // 60 seconds TTL

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

    pub fn resolve(self: *Self, host: []const u8, port: u16) !net.Address {
        const now_ms = std.time.milliTimestamp();

        // Check cache with read lock
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();

            if (self.entries.get(host)) |entry| {
                if (now_ms < entry.expires_at_ms) {
                    var addr = entry.address;
                    addr.setPort(port);
                    return addr;
                }
            }
        }

        // Cache miss or expired — perform DNS lookup
        const addr = try address_mod.resolve(host, port);

        // Update cache with write lock
        {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.entries.fetchRemove(host)) |kv| {
                self.allocator.free(kv.key);
            }

            const owned_host = try self.allocator.dupe(u8, host);
            try self.entries.put(self.allocator, owned_host, .{
                .address = addr,
                .expires_at_ms = now_ms + self.default_ttl_ms,
            });
        }

        return addr;
    }

    pub fn clear(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }
};
