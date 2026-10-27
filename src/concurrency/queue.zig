//! Bounded blocking MPMC queue using Zig 0.17 `std.Io` synchronization.
//!
//! Capacity is fixed at initialization. `push` blocks while full, `tryPush`
//! returns `error.Full` or `error.Busy`, and `close` rejects new work while
//! allowing queued items to drain. The caller must join queue users before
//! `deinit`; the queue owns its ring buffer and borrows the supplied `std.Io`.

const std = @import("std");

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        mutex: std.Io.Mutex = .init,
        notEmpty: std.Io.Condition = .init,
        notFull: std.Io.Condition = .init,
        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        closed: bool = false,
        allocator: std.mem.Allocator,

        /// Initializes a bounded queue with fixed capacity and synchronization I/O.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, capSize: usize) !Self {
            const buf = try allocator.alloc(T, @max(1, capSize));
            return .{ .allocator = allocator, .io = io, .buf = buf };
        }

        /// Close and release the backing ring. All producers and consumers
        /// must have returned before this is called.
        pub fn deinit(self: *Self) void {
            self.close();
            self.allocator.free(self.buf);
        }

        /// Blocks when full until an item is removed or the queue is closed.
        pub fn push(self: *Self, item: T) error{Closed}!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (!self.closed and self.len == self.buf.len) {
                self.notFull.waitUncancelable(self.io, &self.mutex);
            }
            if (self.closed) return error.Closed;
            self.enqueue(item);
            self.notEmpty.signal(self.io);
        }

        /// Nonblocking push. `Busy` means another operation currently owns
        /// the queue lock; this preserves the no-wait contract of trySubmit.
        pub fn tryPush(self: *Self, item: T) error{ Closed, Full, Busy }!void {
            if (!self.mutex.tryLock()) return error.Busy;
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            if (self.len == self.buf.len) return error.Full;
            self.enqueue(item);
            self.notEmpty.signal(self.io);
        }

        /// Blocks while empty. A closed queue drains existing items, then
        /// returns `error.Closed` to all consumers.
        pub fn pop(self: *Self) error{Closed}!T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (!self.closed and self.len == 0) {
                self.notEmpty.waitUncancelable(self.io, &self.mutex);
            }
            if (self.len == 0) return error.Closed;
            const item = self.dequeue();
            self.notFull.signal(self.io);
            return item;
        }

        /// Nonblocking pop. Returns null when empty or contended.
        pub fn tryPop(self: *Self) ?T {
            if (!self.mutex.tryLock()) return null;
            defer self.mutex.unlock(self.io);
            if (self.len == 0) return null;
            const item = self.dequeue();
            self.notFull.signal(self.io);
            return item;
        }

        /// Removes every currently queued item while holding the queue lock.
        /// The callback runs under that lock and must not call back into this
        /// queue. Unlike repeated `tryPop`, contention cannot be mistaken for
        /// an empty queue and leave items behind.
        pub fn drain(self: *Self, context: anytype, comptime callback: anytype) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var countDrained: usize = 0;
            while (self.len != 0) {
                const item = self.dequeue();
                callback(context, item);
                countDrained += 1;
            }
            if (countDrained != 0) self.notFull.broadcast(self.io);
            return countDrained;
        }

        /// Closes the queue and wakes every producer and consumer.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return;
            self.closed = true;
            self.notEmpty.broadcast(self.io);
            self.notFull.broadcast(self.io);
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.closed;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.len;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        fn enqueue(self: *Self, item: T) void {
            self.buf[self.tail] = item;
            self.tail = if (self.tail + 1 == self.buf.len) 0 else self.tail + 1;
            self.len += 1;
        }

        fn dequeue(self: *Self) T {
            const item = self.buf[self.head];
            self.head = if (self.head + 1 == self.buf.len) 0 else self.head + 1;
            self.len -= 1;
            return item;
        }
    };
}

test "queue fifo order" {
    const Q = BoundedQueue(u32);
    const io = std.Io.Threaded.global_single_threaded.io();
    var q = try Q.init(std.testing.allocator, io, 4);
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var q = try Q.init(std.testing.allocator, io, 2);
    defer q.deinit();
    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expectError(error.Full, q.tryPush(3));
    _ = try q.pop();
    try q.tryPush(3);
}

test "queue close drains then rejects producers and consumers" {
    const Q = BoundedQueue(u32);
    const io = std.Io.Threaded.global_single_threaded.io();
    var q = try Q.init(std.testing.allocator, io, 2);
    defer q.deinit();
    try q.push(9);
    q.close();
    try std.testing.expectError(error.Closed, q.push(10));
    try std.testing.expectEqual(@as(u32, 9), try q.pop());
    try std.testing.expectError(error.Closed, q.pop());
}

test "queue capacity one and nonblocking operations" {
    const Q = BoundedQueue(u64);
    const io = std.Io.Threaded.global_single_threaded.io();
    var q = try Q.init(std.testing.allocator, io, 1);
    defer q.deinit();
    try q.tryPush(100);
    try std.testing.expectError(error.Full, q.tryPush(200));
    try std.testing.expectEqual(@as(?u64, 100), q.tryPop());
    try q.push(200);
    try std.testing.expectEqual(@as(u64, 200), try q.pop());
}

test "queue multi-threaded producer-consumer" {
    const Q = BoundedQueue(usize);
    var ctx = try @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator);
    defer ctx.deinit();
    var q = try Q.init(std.testing.allocator, ctx.io, 8);
    defer q.deinit();

    const Producer = struct {
        fn run(queue: *Q, startVal: usize, countVal: usize) void {
            var i: usize = 0;
            while (i < countVal) : (i += 1) queue.push(startVal + i) catch return;
        }
    };
    const Consumer = struct {
        fn run(queue: *Q, totalRecv: *std.atomic.Value(usize), expected: usize) void {
            while (totalRecv.load(.monotonic) < expected) {
                _ = queue.pop() catch break;
                _ = totalRecv.fetchAdd(1, .monotonic);
            }
        }
    };

    var totalRecv = std.atomic.Value(usize).init(0);
    const totalItems: usize = 50;
    const t1 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 0, 25 });
    const t2 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 25, 25 });
    const c1 = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &totalRecv, totalItems });
    const c2 = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &totalRecv, totalItems });
    t1.join();
    t2.join();
    q.close();
    c1.join();
    c2.join();
    try std.testing.expectEqual(totalItems, totalRecv.load(.monotonic));
}
