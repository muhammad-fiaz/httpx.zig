//! Production worker pool: fixed threads, bounded queue, graceful drain.
//!
//! Optional subsystem — a plain Client never creates one. Tasks are
//! `fn (*anyopaque) void` closures; cooperative cancellation is exposed by
//! handing tasks an `*AtomicCancel` flag the body may poll.
//!
//! Thread-safety: WorkerPool is internally synchronized and safe to share
//! across threads after init.

const std = @import("std");
const sync = @import("../common/sync.zig");
const BoundedQueue = @import("queue.zig").BoundedQueue;

pub const TaskFn = *const fn (ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) void;

pub const Config = struct {
    /// 0 => auto (CPU count, clamped 1..16).
    workers: u16 = 0,
    /// Pending-task capacity before submission blocks (or rejects).
    queue_capacity: u32 = 1024,
};

pub const Stats = struct {
    submitted: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),

    pub fn snapshot(self: *const Stats) Stats {
        return .{
            .submitted = .init(self.submitted.load(.monotonic)),
            .completed = .init(self.completed.load(.monotonic)),
            .failed = .init(self.failed.load(.monotonic)),
            .cancelled = .init(self.cancelled.load(.monotonic)),
            .rejected = .init(self.rejected.load(.monotonic)),
        };
    }
};

pub const SubmitError = error{ QueueFull, ShuttingDown, OutOfMemory };

pub const Pool = struct {
    allocator: std.mem.Allocator,
    queue: BoundedQueue(Job),
    threads: []std.Thread,
    stats: Stats = .{},
    shutting_down: std.atomic.Value(bool) = .init(false),
    drain_mode: std.atomic.Value(bool) = .init(false),
    mu: sync.Spinlock = .{},
    started: bool = false,

    const Job = struct {
        run: TaskFn,
        ctx: ?*anyopaque,
        cancel: ?*std.atomic.Value(bool),
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Pool {
        const cap: usize = @max(1, @as(usize, cfg.queue_capacity));
        var n: usize = cfg.workers;
        if (n == 0) {
            n = std.Thread.getCpuCount() catch 4;
            if (n > 16) n = 16;
        }
        return .{
            .allocator = allocator,
            .queue = try BoundedQueue(Job).init(allocator, cap),
            .threads = try allocator.alloc(std.Thread, n),
        };
    }

    /// Spawns worker threads. Safe to call once; extra calls are no-ops.
    pub fn start(self: *Pool) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.started) return;
        for (self.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerMain, .{ self, @as(u32, @intCast(i)) }) catch |e| {
                // Roll back already-spawned workers.
                self.queue.close();
                for (self.threads[0..i]) |*prev| prev.join();
                return e;
            };
        }
        self.started = true;
    }

    pub fn deinit(self: *Pool) void {
        self.shutdownDrain();
        if (self.started) {
            for (self.threads) |*t| t.join();
            self.started = false;
        }
        self.queue.deinit();
        self.allocator.free(self.threads);
    }

    pub fn submit(self: *Pool, run: TaskFn, ctx: ?*anyopaque, cancel: ?*std.atomic.Value(bool)) SubmitError!void {
        if (self.shutting_down.load(.acquire)) return error.ShuttingDown;
        // True backpressure: block while the ring is full. A close() during
        // the wait surfaces as ShuttingDown.
        self.queue.push(.{ .run = run, .ctx = ctx, .cancel = cancel }) catch {
            _ = self.stats.rejected.fetchAdd(1, .monotonic);
            return error.ShuttingDown;
        };
        _ = self.stats.submitted.fetchAdd(1, .monotonic);
    }

    /// Stop accepting new work; finish everything already queued.
    pub fn shutdownDrain(self: *Pool) void {
        if (!self.drain_mode.swap(true, .acq_rel)) {
            self.shutting_down.store(true, .release);
            self.queue.close();
        }
    }

    /// Cooperative cancel signal for all queued-but-not-started jobs.
    pub fn cancelQueued(self: *Pool) void {
        while (self.queue.tryPop()) |job| {
            if (job.cancel) |flag| flag.store(true, .release);
            _ = self.stats.cancelled.fetchAdd(1, .monotonic);
            _ = self.stats.submitted.fetchSub(1, .monotonic);
        }
    }

    fn workerMain(self: *Pool, _: u32) void {
        while (true) {
            const job = self.queue.pop() catch break; // closed+drained
            if (job.cancel) |flag| {
                if (flag.load(.acquire)) {
                    _ = self.stats.cancelled.fetchAdd(1, .monotonic);
                    continue;
                }
            }
            job.run(job.ctx, job.cancel orelse noopCancel());
            _ = self.stats.completed.fetchAdd(1, .monotonic);
        }
    }

    var g_noop align(8) = std.atomic.Value(bool).init(false);
    fn noopCancel() *std.atomic.Value(bool) {
        return &g_noop;
    }
};

test "pool executes submitted tasks" {
    const Ctx = struct {
        counter: std.atomic.Value(u32) = .init(0),
        fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = c.counter.fetchAdd(1, .monotonic);
        }
    };
    var ctx = Ctx{};
    var p = try Pool.init(std.testing.allocator, .{ .workers = 2, .queue_capacity = 8 });
    defer p.deinit();
    try p.start();
    var i: usize = 0;
    while (i < 10) : (i += 1) try p.submit(Ctx.run, &ctx, null);
    // Wait deterministically-ish for completion.
    var spins: usize = 0;
    while (p.stats.completed.load(.monotonic) < 10 and spins < 1_000_000) : (spins += 1)
        std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u64, 10), p.stats.completed.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 10), ctx.counter.load(.monotonic));
}

test "pool rejects when shut down" {
    var p = try Pool.init(std.testing.allocator, .{ .workers = 1 });
    defer p.deinit();
    p.shutdownDrain();
    try std.testing.expectError(error.ShuttingDown, p.submit(dummy, null, null));
}

test "zero workers auto-configures" {
    var p = try Pool.init(std.testing.allocator, .{});
    defer p.deinit();
    try p.start();
    // Auto count is >= 1 thread.
    try std.testing.expect(p.threads.len >= 1);
}

fn dummy(_: ?*anyopaque, _: *std.atomic.Value(bool)) void {}
