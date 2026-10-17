//! Production worker pool: fixed threads, bounded queue, graceful drain.
//!
//! Features:
//!   - Fixed or auto-scaled worker thread count.
//!   - Bounded task queue with backpressure (`submit`) and non-blocking submission (`trySubmit`).
//!   - Safe lifecycle state transitions: `init` -> `start` -> `submit` -> `drain` -> `shutdown` -> `join` -> `deinit`.
//!   - Cancellation support: queued cancellation (`cancelQueued`) and cooperative running task cancellation.
//!   - Comprehensive atomic statistics accounting (submitted, completed, failed, cancelled, rejected).
//!   - Thread-safe across multiple concurrent submitters and threads.

const std = @import("std");
const sync = @import("../common/sync.zig");
const BoundedQueue = @import("queue.zig").BoundedQueue;

pub const TaskFn = *const fn (ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) anyerror!void;

pub const Config = struct {
    /// 0 => auto (CPU count clamped 1..16).
    workers: u16 = 0,
    /// Pending-task capacity before submission blocks (or rejects).
    queueCapacity: u32 = 1024,
    /// If true, automatically starts worker threads on the first submitted task.
    autoStart: bool = true,
};

pub const Stats = struct {
    submitted: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(usize) = .init(0),
    rejected: std.atomic.Value(usize) = .init(0),

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

pub const SubmitError = error{ QueueFull, QueueBusy, ShuttingDown, OutOfMemory };

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: BoundedQueue(Job),
    threads: []std.Thread,
    stats: Stats = .{},
    shuttingDown: std.atomic.Value(bool) = .init(false),
    drainMode: std.atomic.Value(bool) = .init(false),
    cfg: Config,
    mu: sync.Spinlock = .{},
    started: bool = false,

    const Job = struct {
        run: TaskFn,
        ctx: ?*anyopaque,
        cancel: ?*std.atomic.Value(bool),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !Pool {
        const cap: usize = @max(1, @as(usize, cfg.queueCapacity));
        var n: usize = cfg.workers;
        if (n == 0) {
            n = std.Thread.getCpuCount() catch 4;
            if (n > 16) n = 16;
            if (n < 1) n = 1;
        }
        var queue = try BoundedQueue(Job).init(allocator, io, cap);
        errdefer queue.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
            .threads = try allocator.alloc(std.Thread, n),
            .cfg = cfg,
        };
    }

    /// Spawns worker threads. Safe to call multiple times (subsequent calls are no-ops).
    pub fn start(self: *Pool) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.started) return;
        for (self.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerMain, .{ self, @as(u32, @intCast(i)) }) catch |e| {
                // Roll back already-spawned workers cleanly.
                self.shuttingDown.store(true, .release);
                self.queue.close();
                for (self.threads[0..i]) |*prev| prev.join();
                return e;
            };
        }
        self.started = true;
    }

    pub fn deinit(self: *Pool) void {
        self.shutdownDrain();
        self.join();
        self.queue.deinit();
        self.allocator.free(self.threads);
    }

    /// Blocks until all running worker threads exit.
    pub fn join(self: *Pool) void {
        self.mu.lock();
        const wasStarted = self.started;
        self.started = false;
        self.mu.unlock();

        if (wasStarted) {
            for (self.threads) |*t| t.join();
        }
    }

    /// Submits a task for asynchronous execution. Blocks if the queue is full (applying backpressure).
    pub fn submit(self: *Pool, run: TaskFn, ctx: ?*anyopaque, cancel: ?*std.atomic.Value(bool)) SubmitError!void {
        if (self.shuttingDown.load(.acquire)) return error.ShuttingDown;
        if (self.cfg.autoStart and !self.isStarted()) {
            self.start() catch return error.OutOfMemory;
        }

        self.queue.push(.{ .run = run, .ctx = ctx, .cancel = cancel }) catch {
            _ = self.stats.rejected.fetchAdd(1, .monotonic);
            return error.ShuttingDown;
        };
        _ = self.stats.submitted.fetchAdd(1, .monotonic);
    }

    /// Non-blocking task submission. Returns `error.QueueFull` immediately if full.
    pub fn trySubmit(self: *Pool, run: TaskFn, ctx: ?*anyopaque, cancel: ?*std.atomic.Value(bool)) SubmitError!void {
        if (self.shuttingDown.load(.acquire)) return error.ShuttingDown;
        if (self.cfg.autoStart and !self.isStarted()) {
            self.start() catch return error.OutOfMemory;
        }

        self.queue.tryPush(.{ .run = run, .ctx = ctx, .cancel = cancel }) catch |err| switch (err) {
            error.Full => {
                _ = self.stats.rejected.fetchAdd(1, .monotonic);
                return error.QueueFull;
            },
            error.Busy => {
                _ = self.stats.rejected.fetchAdd(1, .monotonic);
                return error.QueueBusy;
            },
            error.Closed => {
                _ = self.stats.rejected.fetchAdd(1, .monotonic);
                return error.ShuttingDown;
            },
        };
        _ = self.stats.submitted.fetchAdd(1, .monotonic);
    }

    /// Stop accepting new work; finish processing everything already queued.
    pub fn shutdownDrain(self: *Pool) void {
        if (!self.drainMode.swap(true, .acq_rel)) {
            self.shuttingDown.store(true, .release);
            self.queue.close();
        }
    }

    /// Cooperative cancel signal for all queued-but-not-started jobs.
    pub fn cancelQueued(self: *Pool) void {
        while (self.queue.tryPop()) |job| {
            if (job.cancel) |flag| flag.store(true, .release);
            _ = self.stats.cancelled.fetchAdd(1, .monotonic);
        }
    }

    pub fn isStarted(self: *Pool) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.started;
    }

    fn workerMain(self: *Pool, _: u32) void {
        while (true) {
            const job = self.queue.pop() catch break; // closed and drained
            if (job.cancel) |flag| {
                if (flag.load(.acquire)) {
                    _ = self.stats.cancelled.fetchAdd(1, .monotonic);
                    continue;
                }
            }
            job.run(job.ctx, job.cancel orelse noopCancel()) catch {
                _ = self.stats.failed.fetchAdd(1, .monotonic);
                continue;
            };
            _ = self.stats.completed.fetchAdd(1, .monotonic);
        }
    }

    var gNoop align(8) = std.atomic.Value(bool).init(false);
    fn noopCancel() *std.atomic.Value(bool) {
        return &gNoop;
    }
};

test "pool executes submitted tasks" {
    const Ctx = struct {
        counter: std.atomic.Value(u32) = .init(0),
        fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = c.counter.fetchAdd(1, .monotonic);
        }
    };
    var ctx = Ctx{};
    const io = std.Io.Threaded.global_single_threaded.io();
    var p = try Pool.init(std.testing.allocator, io, .{ .workers = 2, .queueCapacity = 8 });
    defer p.deinit();
    try p.start();
    var i: usize = 0;
    while (i < 10) : (i += 1) try p.submit(Ctx.run, &ctx, null);

    var spins: usize = 0;
    while (p.stats.completed.load(.monotonic) < 10 and spins < 100_000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 10), p.stats.completed.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 10), ctx.counter.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), p.stats.failed.load(.monotonic));
}

test "pool counts task errors as failures rather than completions" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var p = try Pool.init(std.testing.allocator, io, .{ .workers = 1, .queueCapacity = 1 });
    defer p.deinit();
    try p.submit(failTask, null, null);
    p.shutdownDrain();
    p.join();
    try std.testing.expectEqual(@as(usize, 1), p.stats.submitted.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), p.stats.completed.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), p.stats.failed.load(.monotonic));
}

test "pool rejects when shut down" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var p = try Pool.init(std.testing.allocator, io, .{ .workers = 1 });
    defer p.deinit();
    p.shutdownDrain();
    try std.testing.expectError(error.ShuttingDown, p.submit(dummy, null, null));
}

test "zero workers auto-configures" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var p = try Pool.init(std.testing.allocator, io, .{});
    defer p.deinit();
    try p.start();
    try std.testing.expect(p.threads.len >= 1);
}

test "pool cancel queued tasks" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var p = try Pool.init(std.testing.allocator, io, .{ .workers = 1, .queueCapacity = 16 });
    defer p.deinit();

    var cancelFlag = std.atomic.Value(bool).init(false);
    try p.submit(dummy, null, &cancelFlag);
    p.cancelQueued();
    // Statistics are cumulative: cancellation changes the terminal outcome,
    // not whether a task was accepted by the pool.
    try std.testing.expectEqual(@as(usize, 1), p.stats.submitted.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), p.stats.cancelled.load(.monotonic));
    try p.start();
    p.shutdownDrain();
}

fn dummy(_: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {}

fn failTask(_: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
    return error.TaskFailed;
}
