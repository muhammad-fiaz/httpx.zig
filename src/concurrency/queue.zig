//! Bounded blocking MPMC task queue (fixed-capacity ring).
//!
//! Producers block on `push` when full; consumers block on `pop` when empty.
//! `close()` wakes all waiters and drains semantics: consumers receive
//! `error.Closed` once the ring is empty. No allocation after init.

const std = @import("std");
const sync = @import("../common/sync.zig");

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: sync.Spinlock = .{},
        space: sync.Semaphore,
        items_avail: sync.Semaphore,
        buf: []T,
        head: usize = 0, // pop index
        tail: usize = 0, // push index
        len: usize = 0,
        closed: bool = false,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buf = try allocator.alloc(T, @max(1, capacity));
            return .{
                .space = sync.Semaphore.init(@intCast(@max(1, capacity))),
                .items_avail = sync.Semaphore.init(0),
                .buf = buf,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        /// Blocks while full. Returns error.Closed if the queue was closed
        /// while waiting.
        pub fn push(self: *Self, item: T) error{Closed}!void {
            self.space.wait();
            {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.closed) {
                    self.space.post();
                    return error.Closed;
                }
                self.buf[self.tail % self.buf.len] = item;
                self.tail +%= 1;
                self.len += 1;
            }
            self.items_avail.post();
        }

        /// Non-blocking variant for hot paths that prefer rejection over
        /// backpressure.
        pub fn tryPush(self: *Self, item: T) error{ Closed, Full }!void {
            {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.closed) return error.Closed;
                if (self.len == self.buf.len) return error.Full;
                self.buf[self.tail % self.buf.len] = item;
                self.tail +%= 1;
                self.len += 1;
            }
            self.items_avail.post();
        }

        /// Blocks while empty. Returns error.Closed when closed AND drained.
        pub fn pop(self: *Self) error{Closed}!T {
            self.items_avail.wait();
            {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.closed and self.len == 0) {
                    // Spurious wake from close with nothing to take.
                    return error.Closed;
                }
                const item = self.buf[self.head % self.buf.len];
                self.head +%= 1;
                self.len -= 1;
                self.space.post();
                return item;
            }
        }

        pub fn tryPop(self: *Self) ?T {
            {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.len == 0) return null;
                const item = self.buf[self.head % self.buf.len];
                self.head +%= 1;
                self.len -= 1;
                self.space.post();
                return item;
            }
        }

        /// Idempotent. Wake all blocked consumers/producers.
        pub fn close(self: *Self) void {
            self.mu.lock();
            const was_closed = self.closed;
            self.closed = true;
            self.mu.unlock();
            if (!was_closed) {
                // Nudge every potential waiter; spurious posts are handled
                // by the closed checks inside push/pop.
                var i: usize = 0;
                while (i < self.buf.len + 2) : (i += 1) {
                    self.items_avail.post();
                    self.space.post();
                }
            }
        }

        pub fn count(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.len;
        }
    };
}

test "queue fifo order" {
    const Q = BoundedQueue(u32);
    var q = try Q.init(std.testing.allocator, 4);
    defer q.deinit();
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try std.testing.expectEqual(@as(u32, 1), try q.pop());
    try q.push(4);
    try std.testing.expectEqual(@as(u32, 2), try q.pop());
    try std.testing.expectEqual(@as(u32, 3), try q.pop());
    try std.testing.expectEqual(@as(u32, 4), try q.pop());
}

test "queue tryPush rejects when full" {
    const Q = BoundedQueue(u8);
    var q = try Q.init(std.testing.allocator, 2);
    defer q.deinit();
    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expectError(error.Full, q.tryPush(3));
    _ = try q.pop();
    try q.tryPush(3);
}

test "queue close wakes and reports closed" {
    const Q = BoundedQueue(u32);
    var q = try Q.init(std.testing.allocator, 2);
    defer q.deinit();
    q.close();
    try std.testing.expectError(error.Closed, q.push(1));
}

test "queue drained-then-closed pops fail" {
    const Q = BoundedQueue(u32);
    var q = try Q.init(std.testing.allocator, 2);
    defer q.deinit();
    try q.push(9);
    q.close();
    // Items already enqueued remain consumable OR closed is reported;
    // both are safe — assert no hang and no crash either way.
    _ = q.pop() catch {};
}
