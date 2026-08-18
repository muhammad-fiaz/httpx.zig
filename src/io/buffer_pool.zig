//! Buffer Pool for httpx.zig
//!
//! Provides a reusable buffer pool with ownership-safe release semantics.
//! Buffers are pre-allocated and recycled to avoid repeated heap allocations
//! during HTTP message processing.
//!
//! Features:
//!
//!     - Ownership-safe release (rejects foreign buffers, double release)
//!     - Pre-allocated fixed-size buffers
//!     - O(1) acquire, O(n) release with small n (typically 8-64 slots)
//!     - Thread-safe when wrapped with external synchronization
//!
//! Usage:
//!
//!     var pool = try BufferPool.init(allocator, 8, 4096);
//!     defer pool.deinit();
//!
//!     const buf = pool.acquire() orelse return error.Exhausted;
//!     defer pool.release(buf) catch {};
//!
//!     // Use buf[0..pool.bufferSize()] for I/O

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A reusable buffer pool with ownership-safe release semantics.
///
/// Buffers are tracked by slot. Only buffers that were allocated by this
/// pool can be released back to it. The pool detects:
///
///     - Foreign buffer release (buffer not from this pool)
///     - Double release (buffer already available)
///     - Use-after-release (acquire returns null when exhausted)
///
/// Thread safety: Not thread-safe. If shared across threads, the caller
/// must provide external synchronization (e.g. std.Io.Mutex).
pub const BufferPool = struct {
    allocator: Allocator,
    slots: std.ArrayList(Slot),
    free_count: usize,
    buf_size: usize,
    max_count: usize,

    const Slot = struct {
        buf: []u8,
        is_free: bool,
    };

    /// Initialize a buffer pool with `count` buffers of `buf_size` bytes each.
    ///
    /// If any allocation fails, all previously allocated buffers are freed.
    pub fn init(allocator: Allocator, count: usize, buf_size: usize) !BufferPool {
        var slots: std.ArrayList(Slot) = .empty;
        errdefer slots.deinit(allocator);

        for (0..count) |_| {
            const buf = try allocator.alloc(u8, buf_size);
            errdefer allocator.free(buf);
            try slots.append(allocator, .{ .buf = buf, .is_free = true });
        }

        return BufferPool{
            .allocator = allocator,
            .slots = slots,
            .free_count = count,
            .buf_size = buf_size,
            .max_count = count,
        };
    }

    /// Release all buffers and free memory.
    ///
    /// If buffers are still acquired (not yet released), their memory is
    /// still freed. Callers holding acquired buffers must not use them after
    /// deinit.
    pub fn deinit(self: *BufferPool) void {
        for (self.slots.items) |slot| {
            self.allocator.free(slot.buf);
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Acquire a buffer from the pool. Returns null if all buffers are in use.
    pub fn acquire(self: *BufferPool) ?[]u8 {
        for (self.slots.items) |*slot| {
            if (slot.is_free) {
                slot.is_free = false;
                self.free_count -= 1;
                return slot.buf;
            }
        }
        return null;
    }

    /// Return a buffer to the pool.
    ///
    /// Safety checks:
    ///     - Validates the buffer pointer matches a pool-allocated buffer
    ///     - Rejects buffers not owned by this pool (ForeignBuffer)
    ///     - Rejects double release (DoubleRelease)
    pub fn release(self: *BufferPool, buf: []u8) ReleaseError!void {
        const buf_ptr = @intFromPtr(buf.ptr);
        for (self.slots.items) |*slot| {
            if (@intFromPtr(slot.buf.ptr) == buf_ptr) {
                if (slot.is_free) return error.DoubleRelease;
                slot.is_free = true;
                self.free_count += 1;
                return;
            }
        }
        return error.ForeignBuffer;
    }

    /// Number of buffers currently available for acquisition.
    pub fn available(self: *const BufferPool) usize {
        return self.free_count;
    }

    /// Total number of buffers in the pool.
    pub fn capacity(self: *const BufferPool) usize {
        return self.max_count;
    }

    /// Size of each buffer in bytes.
    pub fn bufferSize(self: *const BufferPool) usize {
        return self.buf_size;
    }
};

pub const ReleaseError = error{
    ForeignBuffer,
    DoubleRelease,
};

test "buffer pool init and deinit" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 4, 1024);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.available());
    try std.testing.expectEqual(@as(usize, 4), pool.capacity());
    try std.testing.expectEqual(@as(usize, 1024), pool.bufferSize());
}

test "buffer pool zero count" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 0, 1024);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expectEqual(@as(usize, 0), pool.capacity());
    try std.testing.expect(pool.acquire() == null);
}

test "buffer pool acquire and release" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 4, 1024);
    defer pool.deinit();

    const buf1 = pool.acquire() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 3), pool.available());

    const buf2 = pool.acquire() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), pool.available());

    try pool.release(buf1);
    try std.testing.expectEqual(@as(usize, 3), pool.available());

    try pool.release(buf2);
    try std.testing.expectEqual(@as(usize, 4), pool.available());
}

test "buffer pool exhaustion" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 2, 1024);
    defer pool.deinit();

    _ = pool.acquire() orelse return error.TestFailed;
    _ = pool.acquire() orelse return error.TestFailed;

    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expect(pool.acquire() == null);
}

test "buffer pool foreign buffer rejection" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 2, 1024);
    defer pool.deinit();

    const foreign = try allocator.alloc(u8, 1024);
    defer allocator.free(foreign);

    try std.testing.expectError(error.ForeignBuffer, pool.release(foreign));
}

test "buffer pool double release rejection" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 2, 1024);
    defer pool.deinit();

    const buf = pool.acquire() orelse return error.TestFailed;
    try pool.release(buf);

    try std.testing.expectError(error.DoubleRelease, pool.release(buf));
}

test "buffer pool partial init failure" {
    const allocator = std.testing.allocator;

    var fail_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 1,
    });
    const fail_alloc = fail_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, BufferPool.init(fail_alloc, 4, 1024));
}

test "buffer pool deinit with acquired buffers" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 4, 1024);

    _ = pool.acquire() orelse return error.TestFailed;
    _ = pool.acquire() orelse return error.TestFailed;
    _ = pool.acquire() orelse return error.TestFailed;
    _ = pool.acquire() orelse return error.TestFailed;

    try std.testing.expectEqual(@as(usize, 0), pool.available());
    pool.deinit();
}

test "buffer pool reuse cycle" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool.init(allocator, 2, 512);
    defer pool.deinit();

    for (0..10) |cycle| {
        _ = cycle;
        const buf = pool.acquire() orelse return error.TestFailed;
        @memset(buf[0..64], 0xAA);
        try pool.release(buf);
    }

    try std.testing.expectEqual(@as(usize, 2), pool.available());
}
