//! Shared synchronization primitives for Zig 0.17 thread and I/O code.
//!
//! Low-overhead primitives for the httpx concurrency model:
//!
//! - `Spinlock` — thin spinlock wrapping `std.atomic.Mutex` (tryLock/unlock).
//! - `Semaphore` — counting semaphore backed by Zig 0.17 `std.Io.Semaphore`.
//!   Waits block through the I/O backend rather than spinning.
//! - `Once` — one-shot initialization gate that ensures a function runs
//!   exactly once across threads.
//!
//! These primitives underpin the worker pool and connection pool
//! subsystems.

const std = @import("std");

/// Blocking spinlock built on `std.atomic.Mutex` (tryLock/unlock).
pub const Spinlock = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn init() Spinlock {
        return .{};
    }

    pub fn lock(self: *Spinlock) void {
        while (!self.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Spinlock) void {
        self.inner.unlock();
    }
};

/// Counting semaphore backed by Zig 0.17's futex-capable `std.Io.Semaphore`.
/// Blocking waits suspend the kernel thread rather than polling. The I/O
/// context is borrowed and must outlive the semaphore's users.
pub const Semaphore = struct {
    io: std.Io,
    inner: std.Io.Semaphore,

    pub fn init(io: std.Io, initial: u32) Semaphore {
        return .{ .io = io, .inner = .{ .permits = initial } };
    }

    pub fn post(self: *Semaphore) void {
        self.inner.post(self.io);
    }

    pub fn wait(self: *Semaphore) void {
        self.inner.waitUncancelable(self.io);
    }

    pub fn tryWait(self: *Semaphore) bool {
        if (!self.inner.mutex.tryLock()) return false;
        defer self.inner.mutex.unlock(self.io);
        if (self.inner.permits == 0) return false;
        self.inner.permits -= 1;
        if (self.inner.permits > 0) self.inner.cond.signal(self.io);
        return true;
    }
};

/// One-shot initialization gate (std.once does not exist in 0.16).
/// `executed()` runs `f` exactly once across all threads; others block
/// until it completes.
pub const Once = struct {
    state: std.atomic.Value(u8) = .init(0), // 0=idle 1=running 2=done
    mu: Spinlock = .{},

    pub fn init() Once {
        return .{};
    }

    pub fn call(self: *Once, comptime f: fn () void) void {
        // Fast path: already done.
        if (self.state.load(.acquire) == 2) return;

        self.mu.lock();
        defer self.mu.unlock();
        switch (self.state.load(.monotonic)) {
            2 => return,
            1 => unreachable, // we hold the lock; cannot be another runner
            else => {},
        }
        self.state.store(1, .monotonic);
        f();
        self.state.store(2, .release);
    }

    pub fn isDone(self: *const Once) bool {
        return self.state.load(.acquire) == 2;
    }
};

test "spinlock basic" {
    var s = Spinlock.init();
    s.lock();
    s.unlock();
    s.lock();
    s.unlock();
}

test "semaphore post/wait" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = Semaphore.init(io, 0);
    try std.testing.expect(!s.tryWait());
    s.post();
    try std.testing.expect(s.tryWait());
    try std.testing.expect(!s.tryWait());
}

test "semaphore initial count" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = Semaphore.init(io, 3);
    s.wait();
    s.wait();
    s.wait();
    // Drained; further wait would block — verify via tryWait instead.
    try std.testing.expect(!s.tryWait());
}

test "once runs exactly once" {
    const Counter = struct {
        var runs: std.atomic.Value(u32) = .init(0);
        fn bump() void {
            _ = runs.fetchAdd(1, .monotonic);
        }
    };
    var o = Once.init();
    o.call(Counter.bump);
    o.call(Counter.bump);
    o.call(Counter.bump);
    try std.testing.expectEqual(@as(u32, 1), Counter.runs.load(.monotonic));
    try std.testing.expect(o.isDone());
}
