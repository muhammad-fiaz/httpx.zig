//! Task Executor for httpx.zig
//!
//! Provides async task execution capabilities:
//!
//! - FIFO Thread pool for parallel execution
//! - Task queuing and scheduling with ring buffers
//! - Lockless task coordination and completion events
//! - Cross-platform thread management

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const io_util = @import("../util/any_io.zig");
const threadIo = io_util.threadIo;

pub const ExecutorError = error{
    TaskQueueFull,
    AlreadyRunning,
    NotRunning,
    WorkerSpawnFailed,
};

/// Task function type.
pub const TaskFn = *const fn (?*anyopaque) void;

/// Task with function and context.
pub const Task = struct {
    func: TaskFn,
    context: ?*anyopaque = null,
    priority: u8 = 0,
};

/// Executor configuration.
pub const ExecutorConfig = struct {
    num_threads: u32 = 0,
    task_queue_size: usize = 1024,
    idle_timeout_ms: u64 = 60_000,
};

/// High-performance thread pool executor for parallel task execution.
pub const Executor = struct {
    allocator: Allocator,
    config: ExecutorConfig,
    tasks: std.Deque(Task) = .empty,
    running: bool = false,
    threads: []Thread = &.{},
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    completed_tasks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_workers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const Self = @This();

    /// Creates an executor with default configuration.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates an executor with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ExecutorConfig) Self {
        var cfg = config;
        if (cfg.num_threads == 0) {
            const cpu_count = std.Thread.getCpuCount() catch 4;
            cfg.num_threads = @max(1, @as(u32, @intCast(cpu_count)));
        }
        if (cfg.task_queue_size == 0) {
            cfg.task_queue_size = 1024;
        }
        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    /// Releases executor resources and stops worker threads.
    pub fn deinit(self: *Self) void {
        self.stop();
        self.tasks.deinit(self.allocator);
        if (self.threads.len > 0) {
            self.allocator.free(self.threads);
            self.threads = &.{};
        }
    }

    /// Submits a task for execution (blocks if queue is full until space is available or error).
    pub fn submit(self: *Self, task: Task) !void {
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        if (self.tasks.len >= self.config.task_queue_size) {
            return ExecutorError.TaskQueueFull;
        }

        try self.tasks.pushBack(self.allocator, task);
        self.cond.signal(io);
    }

    /// Tries to submit a task without blocking.
    /// Returns error.WouldBlock if the mutex is locked,
    /// or error.TaskQueueFull if the queue is full.
    pub fn trySubmit(self: *Self, task: Task) !void {
        if (!self.mutex.tryLock()) {
            return error.WouldBlock;
        }
        const io = threadIo();
        defer self.mutex.unlock(io);

        if (self.tasks.len >= self.config.task_queue_size) {
            return ExecutorError.TaskQueueFull;
        }

        try self.tasks.pushBack(self.allocator, task);
        self.cond.signal(io);
    }

    /// Submits a task and triggers a callback when completed.
    pub fn submitWithCallback(
        self: *Self,
        task: Task,
        callback: *const fn (?*anyopaque) void,
        cb_context: ?*anyopaque,
    ) !void {
        const WrappedContext = struct {
            original_task: Task,
            callback: *const fn (?*anyopaque) void,
            cb_context: ?*anyopaque,
            allocator: Allocator,

            fn wrapper(ctx: ?*anyopaque) void {
                const self_ctx: *@This() = @ptrCast(@alignCast(ctx.?));
                defer self_ctx.allocator.destroy(self_ctx);
                self_ctx.original_task.func(self_ctx.original_task.context);
                self_ctx.callback(self_ctx.cb_context);
            }
        };

        const wrapped = try self.allocator.create(WrappedContext);
        errdefer self.allocator.destroy(wrapped);

        wrapped.* = .{
            .original_task = task,
            .callback = callback,
            .cb_context = cb_context,
            .allocator = self.allocator,
        };

        try self.submit(.{
            .func = WrappedContext.wrapper,
            .context = wrapped,
            .priority = task.priority,
        });
    }

    /// Submits a function for execution.
    pub inline fn execute(self: *Self, func: TaskFn, context: ?*anyopaque) !void {
        try self.submit(.{ .func = func, .context = context });
    }

    /// Submits multiple tasks for execution.
    pub fn executeAll(self: *Self, tasks: []const Task) !void {
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        for (tasks) |task| {
            if (self.tasks.len >= self.config.task_queue_size) {
                return ExecutorError.TaskQueueFull;
            }
            try self.tasks.pushBack(self.allocator, task);
        }

        if (tasks.len > 0) {
            self.cond.broadcast(io);
        }
    }

    /// Starts the executor threads.
    pub fn start(self: *Self) !void {
        if (self.running) return;

        self.threads = try self.allocator.alloc(Thread, self.config.num_threads);
        var spawned: usize = 0;
        self.running = true;

        errdefer {
            const io = threadIo();
            self.mutex.lock(io) catch unreachable;
            self.running = false;
            self.cond.broadcast(io);
            self.mutex.unlock(io);

            for (self.threads[0..spawned]) |t| t.join();
            self.allocator.free(self.threads);
            self.threads = &.{};
        }

        for (self.threads) |*thread| {
            thread.* = try Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }
    }

    /// Stops all executor threads and waits for them to terminate.
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
        self.running = false;
        self.cond.broadcast(io);
        self.mutex.unlock(io);

        for (self.threads) |thread| thread.join();
        if (self.threads.len > 0) {
            self.allocator.free(self.threads);
            self.threads = &.{};
        }
    }

    /// Returns the number of pending tasks in the queue.
    pub fn pendingCount(self: *const Self) usize {
        return self.tasks.len;
    }

    /// Returns true when worker threads are running.
    pub inline fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Returns configured maximum queue capacity.
    pub inline fn queueCapacity(self: *const Self) usize {
        return self.config.task_queue_size;
    }

    /// Returns the count of actively executing workers.
    pub inline fn activeWorkerCount(self: *const Self) usize {
        return self.active_workers.load(.acquire);
    }

    /// Returns total completed tasks.
    pub inline fn completedTaskCount(self: *const Self) usize {
        return self.completed_tasks.load(.acquire);
    }

    /// Runs all currently queued tasks synchronously on the calling thread (FIFO order).
    pub fn runAll(self: *Self) void {
        while (true) {
            const io = threadIo();
            self.mutex.lock(io) catch unreachable;
            const maybe_task = self.tasks.popFront();
            self.mutex.unlock(io);

            if (maybe_task) |task| {
                task.func(task.context);
                _ = self.completed_tasks.fetchAdd(1, .release);
            } else {
                break;
            }
        }
    }

    fn workerLoop(self: *Self) void {
        const io = threadIo();
        while (true) {
            self.mutex.lock(io) catch unreachable;
            while (self.running and self.tasks.len == 0) {
                self.cond.wait(io, &self.mutex) catch unreachable;
            }
            if (!self.running and self.tasks.len == 0) {
                self.mutex.unlock(io);
                break;
            }

            const maybe_task = self.tasks.popFront();
            self.mutex.unlock(io);

            if (maybe_task) |task| {
                _ = self.active_workers.fetchAdd(1, .acq_rel);
                task.func(task.context);
                _ = self.active_workers.fetchSub(1, .acq_rel);
                _ = self.completed_tasks.fetchAdd(1, .release);
            }
        }
    }
};

/// Thread-safe Future representing an asynchronously evaluated value.
pub fn Future(comptime T: type) type {
    return struct {
        result: ?T = null,
        error_val: ?anyerror = null,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        event: std.Io.Event = .unset,

        const Self = @This();

        /// Sets the successful result of the future.
        pub fn setResult(self: *Self, val: T) void {
            self.result = val;
            self.completed.store(true, .release);
            const io = threadIo();
            self.event.set(io);
        }

        /// Sets an error on the future.
        pub fn setError(self: *Self, err: anyerror) void {
            self.error_val = err;
            self.completed.store(true, .release);
            const io = threadIo();
            self.event.set(io);
        }

        /// Waits for the future to complete and returns the result.
        pub fn wait(self: *Self) !T {
            if (!self.completed.load(.acquire)) {
                const io = threadIo();
                self.event.wait(io) catch {};
            }
            if (self.error_val) |err| {
                return err;
            }
            return self.result.?;
        }

        /// Returns the result immediately if available, without blocking.
        pub fn get(self: *const Self) ?T {
            if (self.completed.load(.acquire) and self.error_val == null) {
                return self.result;
            }
            return null;
        }

        /// Returns true if the future has completed.
        pub inline fn isDone(self: *const Self) bool {
            return self.completed.load(.acquire);
        }
    };
}

test "Executor initialization" {
    const allocator = std.testing.allocator;
    var exec = Executor.init(allocator);
    defer exec.deinit();

    try std.testing.expect(exec.config.num_threads > 0);
}

test "Executor initWithConfig applies explicit overrides" {
    const allocator = std.testing.allocator;
    var exec = Executor.initWithConfig(allocator, .{ .num_threads = 2, .task_queue_size = 8, .idle_timeout_ms = 1234 });
    defer exec.deinit();

    try std.testing.expectEqual(@as(u32, 2), exec.config.num_threads);
    try std.testing.expectEqual(@as(usize, 8), exec.config.task_queue_size);
    try std.testing.expectEqual(@as(u64, 1234), exec.config.idle_timeout_ms);
}

test "Executor task submission" {
    const allocator = std.testing.allocator;
    var exec = Executor.init(allocator);
    defer exec.deinit();

    var counter: u32 = 0;
    const Counter = struct {
        fn increment(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    };

    try exec.execute(Counter.increment, &counter);
    exec.runAll();

    try std.testing.expectEqual(@as(u32, 1), counter);
    try std.testing.expectEqual(@as(usize, 1), exec.completedTaskCount());
}

test "Future" {
    var future = Future(i32){};

    try std.testing.expect(!future.isDone());
    try std.testing.expect(future.get() == null);

    future.setResult(42);

    try std.testing.expect(future.isDone());
    try std.testing.expectEqual(@as(i32, 42), future.get().?);
    try std.testing.expectEqual(@as(i32, 42), try future.wait());
}

test "Future error" {
    var future = Future(i32){};

    future.setError(error.ConnectionReset);

    try std.testing.expect(future.isDone());
    try std.testing.expect(future.get() == null);
    try std.testing.expectError(error.ConnectionReset, future.wait());
}

test "Executor executeAll and helpers" {
    const allocator = std.testing.allocator;
    var exec = Executor.initWithConfig(allocator, .{ .task_queue_size = 8 });
    defer exec.deinit();

    try std.testing.expect(!exec.isRunning());
    try std.testing.expectEqual(@as(usize, 8), exec.queueCapacity());

    var counter: u32 = 0;
    const Counter = struct {
        fn increment(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    };

    const tasks = [_]Task{
        .{ .func = Counter.increment, .context = &counter },
        .{ .func = Counter.increment, .context = &counter },
    };

    try exec.executeAll(&tasks);
    try std.testing.expectEqual(@as(usize, 2), exec.pendingCount());

    exec.runAll();
    try std.testing.expectEqual(@as(u32, 2), counter);
    try std.testing.expectEqual(@as(usize, 2), exec.completedTaskCount());
}

test "Executor trySubmit" {
    const allocator = std.testing.allocator;
    var exec = Executor.initWithConfig(allocator, .{ .task_queue_size = 2 });
    defer exec.deinit();

    var counter: u32 = 0;
    const Counter = struct {
        fn increment(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    };

    try exec.trySubmit(.{ .func = Counter.increment, .context = &counter });
    try exec.trySubmit(.{ .func = Counter.increment, .context = &counter });

    // third submission should fail with TaskQueueFull
    const err = exec.trySubmit(.{ .func = Counter.increment, .context = &counter });
    try std.testing.expectError(error.TaskQueueFull, err);

    exec.runAll();
    try std.testing.expectEqual(@as(u32, 2), counter);
}

test "Executor submitWithCallback" {
    const allocator = std.testing.allocator;
    var exec = Executor.init(allocator);
    defer exec.deinit();

    var task_counter: u32 = 0;
    var cb_counter: u32 = 0;

    const Work = struct {
        fn run(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
        fn callback(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    };

    try exec.submitWithCallback(
        .{ .func = Work.run, .context = &task_counter },
        Work.callback,
        &cb_counter,
    );

    exec.runAll();

    try std.testing.expectEqual(@as(u32, 1), task_counter);
    try std.testing.expectEqual(@as(u32, 1), cb_counter);
}
