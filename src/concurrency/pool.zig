//! Concurrent Request Patterns for httpx.zig
//!
//! Provides parallel request execution patterns:
//!
//! - `all`: Execute all requests, wait for all to complete
//! - `any`: Execute all requests, return first successful
//! - `race`: Execute all requests, return first to complete
//! - Batch request building

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const io_util = @import("../util/any_io.zig");
const threadIo = io_util.threadIo;
const dbg = @import("../util/debug.zig");

const Client = @import("../client/client.zig").Client;
const Response = @import("../core/response.zig").Response;
const types = @import("../core/types.zig");

/// Request specification for batch operations.
pub const RequestSpec = struct {
    method: types.Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    json: ?[]const u8 = null,
    headers: ?[]const [2][]const u8 = null,
    timeout_ms: ?u64 = null,
    follow_redirects: ?bool = null,
    version: ?types.Version = null,
};

/// Result of a parallel request.
pub const RequestResult = union(enum) {
    success: Response,
    err: anyerror,

    pub fn isSuccess(self: RequestResult) bool {
        return self == .success;
    }

    pub fn getResponse(self: *RequestResult) ?*Response {
        switch (self.*) {
            .success => |*r| return r,
            .err => return null,
        }
    }

    pub fn deinit(self: *RequestResult) void {
        switch (self.*) {
            .success => |*r| r.deinit(),
            .err => {},
        }
    }
};

/// Batch request builder for parallel execution.
pub const BatchBuilder = struct {
    allocator: Allocator,
    requests: std.ArrayList(RequestSpec) = .empty,

    const Self = @This();

    /// Creates a new batch builder.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Releases builder resources.
    pub fn deinit(self: *Self) void {
        self.requests.deinit(self.allocator);
    }

    /// Adds a GET request to the batch.
    pub fn get(self: *Self, url: []const u8) !*Self {
        try self.requests.append(self.allocator, .{ .method = .GET, .url = url });
        return self;
    }

    /// Adds a POST request to the batch.
    pub fn post(self: *Self, url: []const u8, body: ?[]const u8) !*Self {
        try self.requests.append(self.allocator, .{ .method = .POST, .url = url, .body = body });
        return self;
    }

    /// Adds a POST request with a JSON body to the batch.
    pub fn postJson(self: *Self, url: []const u8, json: []const u8) !*Self {
        try self.requests.append(self.allocator, .{ .method = .POST, .url = url, .json = json });
        return self;
    }

    /// Adds a PUT request to the batch.
    pub fn put(self: *Self, url: []const u8, body: ?[]const u8) !*Self {
        try self.requests.append(self.allocator, .{ .method = .PUT, .url = url, .body = body });
        return self;
    }

    /// Adds a DELETE request to the batch.
    pub fn delete(self: *Self, url: []const u8) !*Self {
        try self.requests.append(self.allocator, .{ .method = .DELETE, .url = url });
        return self;
    }

    /// Adds a custom request to the batch.
    pub fn add(self: *Self, spec: RequestSpec) !*Self {
        try self.requests.append(self.allocator, spec);
        return self;
    }

    /// Returns the number of requests in the batch.
    pub fn count(self: *const Self) usize {
        return self.requests.items.len;
    }

    /// Clears all requests from the batch.
    pub fn clear(self: *Self) void {
        self.requests.clearRetainingCapacity();
    }
};

pub const ConcurrencyMode = enum {
    single_thread,
    multi_thread,
    explicit_workers,
};

pub const ConcurrencyConfig = struct {
    mode: ConcurrencyMode = .multi_thread,
    workers: ?u32 = null,
    executor: ?*@import("executor.zig").Executor = null,
};

/// Executes all requests and waits for all to complete.
pub fn all(allocator: Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) ![]RequestResult {
    dbg.entry("BATCH", "all");
    dbg.log("BATCH", "request count: {d}", .{specs.len});
    var results = try allocator.alloc(RequestResult, specs.len);
    errdefer allocator.free(results);

    if (specs.len == 0) return results;

    switch (config.mode) {
        .single_thread => {
            for (specs, 0..) |spec, i| {
                results[i] = executeSpec(client, spec);
            }
        },
        .multi_thread => {
            const workers_count = @max(1, @min(config.workers orelse specs.len, specs.len));
            var next_spec_idx = std.atomic.Value(usize).init(0);

            const Worker = struct {
                client: *Client,
                specs: []const RequestSpec,
                results: []RequestResult,
                next_idx: *std.atomic.Value(usize),

                fn run(self: *@This()) void {
                    while (true) {
                        const idx = self.next_idx.fetchAdd(1, .acq_rel);
                        if (idx >= self.specs.len) break;
                        self.results[idx] = executeSpec(self.client, self.specs[idx]);
                    }
                }
            };

            var threads = try allocator.alloc(Thread, workers_count);
            defer allocator.free(threads);

            var workers = try allocator.alloc(Worker, workers_count);
            defer allocator.free(workers);

            var spawned: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < spawned) : (i += 1) {
                    threads[i].join();
                }
            }

            for (0..workers_count) |i| {
                workers[i] = .{
                    .client = client,
                    .specs = specs,
                    .results = results,
                    .next_idx = &next_spec_idx,
                };
                threads[i] = try Thread.spawn(.{}, Worker.run, .{&workers[i]});
                spawned += 1;
            }

            for (threads[0..spawned]) |t| {
                t.join();
            }
        },
        .explicit_workers => {
            const exec = config.executor orelse return error.MissingExecutor;
            var remaining = std.atomic.Value(usize).init(specs.len);
            var mutex: std.Io.Mutex = .init;
            var cond: std.Io.Condition = .init;

            const TaskCtx = struct {
                client: *Client,
                spec: RequestSpec,
                out: *RequestResult,
                remaining: *std.atomic.Value(usize),
                mutex: *std.Io.Mutex,
                cond: *std.Io.Condition,

                fn run(ctx_ptr: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
                    self.out.* = executeSpec(self.client, self.spec);
                    const prev = self.remaining.fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        const io = threadIo();
                        self.mutex.lock(io) catch unreachable;
                        self.cond.signal(io);
                        self.mutex.unlock(io);
                    }
                }
            };

            var ctxs = try allocator.alloc(TaskCtx, specs.len);
            defer allocator.free(ctxs);

            for (specs, 0..) |spec, i| {
                ctxs[i] = .{
                    .client = client,
                    .spec = spec,
                    .out = &results[i],
                    .remaining = &remaining,
                    .mutex = &mutex,
                    .cond = &cond,
                };
                try exec.submit(.{
                    .func = TaskCtx.run,
                    .context = &ctxs[i],
                });
            }

            const io = threadIo();
            mutex.lock(io) catch unreachable;
            while (remaining.load(.acquire) > 0) {
                cond.wait(io, &mutex) catch unreachable;
            }
            mutex.unlock(io);
        },
    }

    return results;
}

/// Executes all requests and returns results for each one.
///
/// Unlike `all`, this never fails due to a request error; request failures are
/// represented as `RequestResult.err` values.
pub fn allSettled(allocator: Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) ![]RequestResult {
    dbg.entry("BATCH", "allSettled");
    dbg.log("BATCH", "request count: {d}", .{specs.len});
    return all(allocator, client, specs, config);
}

/// Counts successful request results.
pub fn successfulCount(results: []const RequestResult) usize {
    var count: usize = 0;
    for (results) |result| {
        if (result == .success) count += 1;
    }
    return count;
}

/// Counts failed request results.
pub fn errorCount(results: []const RequestResult) usize {
    return results.len - successfulCount(results);
}

/// Executes all requests and returns the first successful response.
pub fn any(allocator: Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !?Response {
    dbg.entry("BATCH", "any");
    dbg.log("BATCH", "request count: {d}", .{specs.len});
    if (specs.len == 0) return null;

    switch (config.mode) {
        .single_thread => {
            for (specs) |spec| {
                var r = executeSpec(client, spec);
                if (r == .success and r.success.status.isSuccess()) {
                    const res = r.success;
                    r = .{ .err = error.UnusedResult };
                    return res;
                }
                r.deinit();
            }
            return null;
        },
        .multi_thread => {
            const workers_count = @max(1, @min(config.workers orelse specs.len, specs.len));
            var next_spec_idx = std.atomic.Value(usize).init(0);
            var winner = std.atomic.Value(bool).init(false);
            var remaining = std.atomic.Value(usize).init(specs.len);
            var mutex: std.Io.Mutex = .init;
            var cond: std.Io.Condition = .init;
            var result: ?Response = null;

            const Worker = struct {
                client: *Client,
                specs: []const RequestSpec,
                next_idx: *std.atomic.Value(usize),
                winner: *std.atomic.Value(bool),
                result: *?Response,
                mutex: *std.Io.Mutex,
                cond: *std.Io.Condition,
                remaining: *std.atomic.Value(usize),

                fn run(self: *@This()) void {
                    while (true) {
                        if (self.winner.load(.acquire)) break;
                        const idx = self.next_idx.fetchAdd(1, .acq_rel);
                        if (idx >= self.specs.len) break;

                        var rr = executeSpec(self.client, self.specs[idx]);
                        defer rr.deinit();

                        if (rr == .success and rr.success.status.isSuccess()) {
                            if (!self.winner.swap(true, .acq_rel)) {
                                const io = threadIo();
                                self.mutex.lock(io) catch unreachable;
                                self.result.* = rr.success;
                                rr = .{ .err = error.UnusedResult }; // transfer ownership
                                self.cond.signal(io);
                                self.mutex.unlock(io);
                                break;
                            }
                        }

                        const prev = self.remaining.fetchSub(1, .acq_rel);
                        if (prev == 1) {
                            const io = threadIo();
                            self.mutex.lock(io) catch unreachable;
                            self.cond.signal(io);
                            self.mutex.unlock(io);
                        }
                    }
                }
            };

            var threads = try allocator.alloc(Thread, workers_count);
            defer allocator.free(threads);

            var workers = try allocator.alloc(Worker, workers_count);
            defer allocator.free(workers);

            var spawned: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < spawned) : (i += 1) threads[i].join();
                if (result) |*r| r.deinit();
            }

            for (0..workers_count) |i| {
                workers[i] = .{
                    .client = client,
                    .specs = specs,
                    .next_idx = &next_spec_idx,
                    .winner = &winner,
                    .result = &result,
                    .mutex = &mutex,
                    .cond = &cond,
                    .remaining = &remaining,
                };
                threads[i] = try Thread.spawn(.{}, Worker.run, .{&workers[i]});
                spawned += 1;
            }

            const any_io = threadIo();
            mutex.lock(any_io) catch unreachable;
            while (!winner.load(.acquire) and remaining.load(.acquire) > (specs.len - spawned)) {
                cond.wait(any_io, &mutex) catch unreachable;
            }
            mutex.unlock(any_io);

            for (threads[0..spawned]) |t| t.join();

            return result;
        },
        .explicit_workers => {
            const exec = config.executor orelse return error.MissingExecutor;
            var winner = std.atomic.Value(bool).init(false);
            var remaining = std.atomic.Value(usize).init(specs.len);
            var mutex: std.Io.Mutex = .init;
            var cond: std.Io.Condition = .init;
            var result: ?Response = null;

            const TaskCtx = struct {
                client: *Client,
                spec: RequestSpec,
                winner: *std.atomic.Value(bool),
                result: *?Response,
                mutex: *std.Io.Mutex,
                cond: *std.Io.Condition,
                remaining: *std.atomic.Value(usize),

                fn run(ctx_ptr: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
                    if (self.winner.load(.acquire)) {
                        _ = self.remaining.fetchSub(1, .acq_rel);
                        return;
                    }

                    var rr = executeSpec(self.client, self.spec);
                    defer rr.deinit();

                    if (rr == .success and rr.success.status.isSuccess()) {
                        if (!self.winner.swap(true, .acq_rel)) {
                            const io = threadIo();
                            self.mutex.lock(io) catch unreachable;
                            self.result.* = rr.success;
                            rr = .{ .err = error.UnusedResult };
                            self.cond.signal(io);
                            self.mutex.unlock(io);
                        }
                    }

                    const prev = self.remaining.fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        const io = threadIo();
                        self.mutex.lock(io) catch unreachable;
                        self.cond.signal(io);
                        self.mutex.unlock(io);
                    }
                }
            };

            var ctxs = try allocator.alloc(TaskCtx, specs.len);
            defer allocator.free(ctxs);

            for (specs, 0..) |spec, i| {
                ctxs[i] = .{
                    .client = client,
                    .spec = spec,
                    .winner = &winner,
                    .result = &result,
                    .mutex = &mutex,
                    .cond = &cond,
                    .remaining = &remaining,
                };
                try exec.submit(.{
                    .func = TaskCtx.run,
                    .context = &ctxs[i],
                });
            }

            const io = threadIo();
            mutex.lock(io) catch unreachable;
            while (!winner.load(.acquire) and remaining.load(.acquire) > 0) {
                cond.wait(io, &mutex) catch unreachable;
            }
            mutex.unlock(io);

            return result;
        },
    }
}

/// Executes all requests and returns the first to complete.
pub fn race(allocator: Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !RequestResult {
    dbg.entry("BATCH", "race");
    dbg.log("BATCH", "request count: {d}", .{specs.len});
    if (specs.len == 0) return .{ .err = error.NoRequests };

    switch (config.mode) {
        .single_thread => {
            return executeSpec(client, specs[0]);
        },
        .multi_thread => {
            const workers_count = @max(1, @min(config.workers orelse specs.len, specs.len));
            var next_spec_idx = std.atomic.Value(usize).init(0);
            var winner = std.atomic.Value(bool).init(false);
            var remaining = std.atomic.Value(usize).init(specs.len);
            var mutex: std.Io.Mutex = .init;
            var cond: std.Io.Condition = .init;
            var result: RequestResult = .{ .err = error.NoRequests };

            const Worker = struct {
                client: *Client,
                specs: []const RequestSpec,
                next_idx: *std.atomic.Value(usize),
                winner: *std.atomic.Value(bool),
                result: *RequestResult,
                mutex: *std.Io.Mutex,
                cond: *std.Io.Condition,
                remaining: *std.atomic.Value(usize),

                fn run(self: *@This()) void {
                    while (true) {
                        if (self.winner.load(.acquire)) break;
                        const idx = self.next_idx.fetchAdd(1, .acq_rel);
                        if (idx >= self.specs.len) break;

                        var rr = executeSpec(self.client, self.specs[idx]);

                        if (!self.winner.swap(true, .acq_rel)) {
                            const io = threadIo();
                            self.mutex.lock(io) catch unreachable;
                            self.result.* = rr;
                            rr = .{ .err = error.UnusedResult };
                            self.cond.signal(io);
                            self.mutex.unlock(io);
                            break;
                        }

                        rr.deinit();

                        const prev = self.remaining.fetchSub(1, .acq_rel);
                        if (prev == 1) {
                            const io = threadIo();
                            self.mutex.lock(io) catch unreachable;
                            self.cond.signal(io);
                            self.mutex.unlock(io);
                        }
                    }
                }
            };

            var threads = try allocator.alloc(Thread, workers_count);
            defer allocator.free(threads);

            var workers = try allocator.alloc(Worker, workers_count);
            defer allocator.free(workers);

            var spawned: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < spawned) : (i += 1) threads[i].join();
                result.deinit();
            }

            for (0..workers_count) |i| {
                workers[i] = .{
                    .client = client,
                    .specs = specs,
                    .next_idx = &next_spec_idx,
                    .winner = &winner,
                    .result = &result,
                    .mutex = &mutex,
                    .cond = &cond,
                    .remaining = &remaining,
                };
                threads[i] = try Thread.spawn(.{}, Worker.run, .{&workers[i]});
                spawned += 1;
            }

            const race_io = threadIo();
            mutex.lock(race_io) catch unreachable;
            while (!winner.load(.acquire) and remaining.load(.acquire) > (specs.len - spawned)) {
                cond.wait(race_io, &mutex) catch unreachable;
            }
            mutex.unlock(race_io);

            for (threads[0..spawned]) |t| t.join();

            return result;
        },
        .explicit_workers => {
            const exec = config.executor orelse return error.MissingExecutor;
            var winner = std.atomic.Value(bool).init(false);
            var remaining = std.atomic.Value(usize).init(specs.len);
            var mutex: std.Io.Mutex = .init;
            var cond: std.Io.Condition = .init;
            var result: RequestResult = .{ .err = error.NoRequests };

            const TaskCtx = struct {
                client: *Client,
                spec: RequestSpec,
                winner: *std.atomic.Value(bool),
                result: *RequestResult,
                mutex: *std.Io.Mutex,
                cond: *std.Io.Condition,
                remaining: *std.atomic.Value(usize),

                fn run(ctx_ptr: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
                    if (self.winner.load(.acquire)) {
                        _ = self.remaining.fetchSub(1, .acq_rel);
                        return;
                    }

                    var rr = executeSpec(self.client, self.spec);

                    if (!self.winner.swap(true, .acq_rel)) {
                        const io = threadIo();
                        self.mutex.lock(io) catch unreachable;
                        self.result.* = rr;
                        rr = .{ .err = error.UnusedResult };
                        self.cond.signal(io);
                        self.mutex.unlock(io);
                    }

                    rr.deinit();

                    const prev = self.remaining.fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        const io = threadIo();
                        self.mutex.lock(io) catch unreachable;
                        self.cond.signal(io);
                        self.mutex.unlock(io);
                    }
                }
            };

            var ctxs = try allocator.alloc(TaskCtx, specs.len);
            defer allocator.free(ctxs);

            for (specs, 0..) |spec, i| {
                ctxs[i] = .{
                    .client = client,
                    .spec = spec,
                    .winner = &winner,
                    .result = &result,
                    .mutex = &mutex,
                    .cond = &cond,
                    .remaining = &remaining,
                };
                try exec.submit(.{
                    .func = TaskCtx.run,
                    .context = &ctxs[i],
                });
            }

            const io = threadIo();
            mutex.lock(io) catch unreachable;
            while (!winner.load(.acquire) and remaining.load(.acquire) > 0) {
                cond.wait(io, &mutex) catch unreachable;
            }
            mutex.unlock(io);

            return result;
        },
    }
}

fn executeSpec(client: *Client, spec: RequestSpec) RequestResult {
    const result = client.request(spec.method, spec.url, .{
        .body = spec.body,
        .json = spec.json,
        .headers = spec.headers,
        .timeout_ms = spec.timeout_ms,
        .follow_redirects = spec.follow_redirects,
        .version = spec.version,
    });

    if (result) |response| {
        return .{ .success = response };
    } else |err| {
        return .{ .err = err };
    }
}

test "BatchBuilder" {
    const allocator = std.testing.allocator;
    var builder = BatchBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.get("http://httpbun.com/users");
    _ = try builder.post("http://httpbun.com/users", "{\"name\":\"test\"}");
    _ = try builder.postJson("http://httpbun.com/users", "{\"name\":\"json\"}");

    try std.testing.expectEqual(@as(usize, 3), builder.count());
}

test "BatchBuilder clear" {
    const allocator = std.testing.allocator;
    var builder = BatchBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.get("http://httpbun.com");
    try std.testing.expectEqual(@as(usize, 1), builder.count());

    builder.clear();
    try std.testing.expectEqual(@as(usize, 0), builder.count());
}

test "RequestResult" {
    var success_result = RequestResult{ .err = error.OutOfMemory };
    try std.testing.expect(!success_result.isSuccess());

    success_result.deinit();
}

test "RequestSpec" {
    const spec = RequestSpec{
        .method = .POST,
        .url = "http://httpbun.com",
        .body = "{\"key\":\"value\"}",
        .timeout_ms = 2_000,
        .follow_redirects = false,
        .version = .HTTP_2,
    };

    try std.testing.expectEqual(types.Method.POST, spec.method);
    try std.testing.expect(spec.body != null);
    try std.testing.expectEqual(@as(u64, 2_000), spec.timeout_ms.?);
    try std.testing.expect(!spec.follow_redirects.?);
    try std.testing.expectEqual(types.Version.HTTP_2, spec.version.?);
}

test "allSettled empty" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    const results = try allSettled(allocator, &client, &.{}, .{});
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "RequestResult summary helpers" {
    const results = [_]RequestResult{
        .{ .err = error.OutOfMemory },
        .{ .err = error.ConnectionRefused },
    };

    try std.testing.expectEqual(@as(usize, 0), successfulCount(&results));
    try std.testing.expectEqual(@as(usize, 2), errorCount(&results));
}

test "ConcurrencyConfig modes execution" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = Client.initWithConfig(allocator, .{
        .timeouts = .uniform(250),
        .keep_alive = false,
    });
    defer client.deinit();

    const specs = [_]RequestSpec{
        .{ .method = .GET, .url = "http://127.0.0.1:1", .timeout_ms = 250 },
        .{ .method = .GET, .url = "http://127.0.0.1:1", .timeout_ms = 250 },
    };

    // 1. Test single_thread mode
    const st_results = try all(allocator, &client, &specs, .{ .mode = .single_thread });
    defer allocator.free(st_results);
    try std.testing.expectEqual(specs.len, st_results.len);
    for (st_results) |r| {
        try std.testing.expect(!r.isSuccess());
    }

    // 2. Test multi_thread mode (implicit workers)
    const mt_results = try all(allocator, &client, &specs, .{ .mode = .multi_thread, .workers = 2 });
    defer allocator.free(mt_results);
    try std.testing.expectEqual(specs.len, mt_results.len);
    for (mt_results) |r| {
        try std.testing.expect(!r.isSuccess());
    }

    // 3. Test explicit_workers mode
    var exec = @import("executor.zig").Executor.initWithConfig(allocator, .{ .num_threads = 2 });
    defer exec.deinit();
    try exec.start();

    const ex_results = try all(allocator, &client, &specs, .{ .mode = .explicit_workers, .executor = &exec });
    defer allocator.free(ex_results);
    try std.testing.expectEqual(specs.len, ex_results.len);
    for (ex_results) |r| {
        try std.testing.expect(!r.isSuccess());
    }
}
