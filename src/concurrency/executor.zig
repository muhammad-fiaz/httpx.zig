//! Task Executor for httpx.zig
//!
//! Provides async task execution capabilities:
//!
//! - Thread pool for parallel execution
//! - Task queuing and scheduling
//! - Work stealing for load balancing
//! - Cross-platform thread management

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const io_util = @import("../util/any_io.zig");
const threadIo = io_util.threadIo;
const dbg = @import("../util/debug.zig");

fn sleepNs(ns: i96) void {
    const io = threadIo();
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(ns), .real) catch {};
}

pub const ExecutorError = error{
    TaskQueueFull,
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

/// Thread pool executor for parallel task execution.
pub const Executor = struct {
    allocator: Allocator,
    config: ExecutorConfig,
    tasks: std.ArrayList(Task) = .empty,
    running: bool = false,
    threads: []Thread = &.{},
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    const Self = @This();

    /// Creates an executor with default configuration.
    pub fn init(allocator: Allocator) Self {
        dbg.entry("EXEC", "init");
        defer dbg.exit("EXEC", "init");
        return initWithConfig(allocator, .{});
    }

    /// Creates an executor with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ExecutorConfig) Self {
        dbg.entry("EXEC", "initWithConfig");
        defer dbg.exit("EXEC", "initWithConfig");
        var cfg = config;
        if (cfg.num_threads == 0) {
            const cpu_count = std.Thread.getCpuCount() catch 4;
            cfg.num_threads = @max(1, @as(u32, @intCast(cpu_count)));
        }
        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    /// Releases executor resources.
    pub fn deinit(self: *Self) void {
        dbg.entry("EXEC", "deinit");
        defer dbg.exit("EXEC", "deinit");
        self.stop();
        self.tasks.deinit(self.allocator);
        if (self.threads.len > 0) {
            self.allocator.free(self.threads);
        }
    }

    /// Submits a task for execution.
    pub fn submit(self: *Self, task: Task) !void {
        dbg.entry("EXEC", "submit");
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        if (self.tasks.items.len >= self.config.task_queue_size) {
            return ExecutorError.TaskQueueFull;
        }

        try self.tasks.append(self.allocator, task);
        self.cond.signal(threadIo());
    }

    /// Tries to submit a task without blocking.
    /// Returns error.WouldBlock if the mutex is locked,
    /// or error.TaskQueueFull if the queue is full.
    pub fn trySubmit(self: *Self, task: Task) !void {
        if (!self.mutex.tryLock()) {
            return error.WouldBlock;
        }
        defer self.mutex.unlock(threadIo());

        if (self.tasks.items.len >= self.config.task_queue_size) {
            return ExecutorError.TaskQueueFull;
        }

        try self.tasks.append(self.allocator, task);
        self.cond.signal(threadIo());
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
                self_ctx.original_task.func(self_ctx.original_task.context);
                self_ctx.callback(self_ctx.cb_context);
                self_ctx.allocator.destroy(self_ctx);
            }
        };

        const wrapped = try self.allocator.create(WrappedContext);
        wrapped.* = .{
            .original_task = task,
            .callback = callback,
            .cb_context = cb_context,
            .allocator = self.allocator,
        };

        self.submit(.{
            .func = WrappedContext.wrapper,
            .context = wrapped,
            .priority = task.priority,
        }) catch |err| {
            self.allocator.destroy(wrapped);
            return err;
        };
    }

    /// Submits a function for execution.
    pub fn execute(self: *Self, func: TaskFn, context: ?*anyopaque) !void {
        try self.submit(.{ .func = func, .context = context });
    }

    /// Submits multiple tasks for execution.
    pub fn executeAll(self: *Self, tasks: []const Task) !void {
        for (tasks) |task| {
            try self.submit(task);
        }
    }

    /// Starts the executor threads.
    pub fn start(self: *Self) !void {
        if (self.running) return;
        self.running = true;

        self.threads = try self.allocator.alloc(Thread, self.config.num_threads);

        for (self.threads) |*thread| {
            thread.* = try Thread.spawn(.{}, workerLoop, .{self});
        }
    }

    /// Stops all executor threads.
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
        self.running = false;
        self.cond.broadcast(io);
        self.mutex.unlock(io);

        for (self.threads) |thread| thread.join();
    }

    /// Returns the number of pending tasks.
    pub fn pendingCount(self: *const Self) usize {
        // best-effort snapshot
        return self.tasks.items.len;
    }

    /// Returns true when worker threads are running.
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Returns configured maximum queue capacity.
    pub fn queueCapacity(self: *const Self) usize {
        return self.config.task_queue_size;
    }

    /// Runs all tasks synchronously.
    pub fn runAll(self: *Self) void {
        while (true) {
            const io = threadIo();
            self.mutex.lock(io) catch unreachable;
            if (self.tasks.items.len == 0) {
                self.mutex.unlock(io);
                break;
            }
            const idx = self.tasks.items.len - 1;
            const task = self.tasks.items[idx];
            self.tasks.items.len = idx;
            self.mutex.unlock(io);

            task.func(task.context);
        }
    }

    fn workerLoop(self: *Self) void {
        while (true) {
            const io = threadIo();
            self.mutex.lock(io) catch unreachable;
            while (self.running and self.tasks.items.len == 0) {
                self.cond.wait(io, &self.mutex) catch unreachable;
            }
            if (!self.running) {
                self.mutex.unlock(io);
                break;
            }

            const idx = self.tasks.items.len - 1;
            const task = self.tasks.items[idx];
            self.tasks.items.len = idx;
            self.mutex.unlock(io);

            task.func(task.context);
        }
    }
};

/// Future representing a pending result.
pub fn Future(comptime T: type) type {
    return struct {
        result: ?T = null,
        error_val: ?anyerror = null,
        completed: bool = false,

        const Self = @This();

        /// Waits for the future to complete.
        pub fn wait(self: *Self) !T {
            while (!self.completed) {
                sleepNs(1_000_000);
            }
            if (self.error_val) |err| {
                return err;
            }
            return self.result.?;
        }

        /// Returns the result if available.
        pub fn get(self: *const Self) ?T {
            if (self.completed and self.error_val == null) {
                return self.result;
            }
            return null;
        }

        /// Returns true if the future is completed.
        pub fn isDone(self: *const Self) bool {
            return self.completed;
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
}

test "Future" {
    var future = Future(i32){};

    try std.testing.expect(!future.isDone());
    try std.testing.expect(future.get() == null);

    future.result = 42;
    future.completed = true;

    try std.testing.expect(future.isDone());
    try std.testing.expectEqual(@as(i32, 42), future.get().?);
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
