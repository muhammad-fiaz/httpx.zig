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
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *Self, host: []const u8, port: u16) !net.Address {
        const now_ms = @import("../util/common.zig").nowMillis();

        // Check cache
        {
            self.lock.lock(threadIo()) catch unreachable;
            defer self.lock.unlock(threadIo());

            if (self.entries.get(host)) |entry| {
                if (now_ms < entry.expires_at_ms) {
                    var addr = entry.address;
                    addr.setPort(port);
                    return addr;
                }
            }
        }

        // Cache miss — resolve and store
        const addr = try address_mod.resolve(self.allocator, host, port);

        {
            self.lock.lock(threadIo()) catch unreachable;
            defer self.lock.unlock(threadIo());

            const key = try self.allocator.dupe(u8, host);
            self.entries.put(self.allocator, key, .{
                .address = addr,
                .expires_at_ms = now_ms + self.default_ttl_ms,
            }) catch {
                self.allocator.free(key);
            };
        }

        return addr;
    }
};
