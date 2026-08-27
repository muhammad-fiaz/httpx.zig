//! Shared synchronization primitives (Zig 0.16 std.Thread has no Mutex).

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

/// Counting semaphore. Blocking waits spin with a yield backoff — no OS
/// futex dependency. Acquire uses CAS so permits can never be duplicated.
pub const Semaphore = struct {
    count: std.atomic.Value(u32),

    pub fn init(initial: u32) Semaphore {
        return .{ .count = .init(initial) };
    }

    pub fn post(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .release);
    }

    /// CAS-based acquire: decrements only when a positive count is observed,
    /// so concurrent post/wait can never manufacture extra permits.
    pub fn wait(self: *Semaphore) void {
        var spins: usize = 0;
        while (true) {
            const c = self.count.load(.acquire);
            if (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acq_rel, .monotonic) == null) return;
                continue;
            }
            spins += 1;
            if (spins < 64) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn tryWait(self: *Semaphore) bool {
        while (true) {
            const c = self.count.load(.acquire);
            if (c == 0) return false;
            if (self.count.cmpxchgWeak(c, c - 1, .acq_rel, .monotonic) == null) return true;
        }
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
    var s = Semaphore.init(0);
    try std.testing.expect(!s.tryWait());
    s.post();
    try std.testing.expect(s.tryWait());
    try std.testing.expect(!s.tryWait());
}

test "semaphore initial count" {
    var s = Semaphore.init(3);
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
