//! Thread-safe request capture for the testing server.
//!
//! Capture is bounded in both retention (number of requests) and copied bytes
//! (per-request body and header budget), so a test cannot grow the process
//! without limit. The total counter keeps counting after retention fills.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zigantic");
const common = @import("common.zig");

const CaptureConfigSchema = z.objectOf(.{
    // When false, requests are counted but not retained.
    .enabled = z.withDefault(z.boolean(.{}), true),
    // Maximum retained requests. Oldest entries are evicted first.
    .maxEntries = z.withDefault(z.nonNegativeInt(usize, .{}), 256),
    // Maximum body bytes copied per request. Larger bodies are truncated
    // while `bodySize` still reports the full body length.
    .maxBody = z.withDefault(z.nonNegativeInt(usize, .{}), 64 * 1024),
    // Maximum header bytes copied per request (names plus values).
    .maxHeader = z.withDefault(z.nonNegativeInt(usize, .{}), 16 * 1024),
}, .{});

/// Validated capture limits. Use `.{}` for bounded defaults.
pub const CaptureConfig = CaptureConfigSchema.Value;

fn validate(config: CaptureConfig) !CaptureConfig {
    var scratch: [1024]u8 = undefined;
    const issue = z.checkFirst(CaptureConfigSchema, config, &scratch, .{}) catch
        return error.InvalidCaptureConfig;
    if (issue != null) return error.InvalidCaptureConfig;
    return config;
}

/// An owned copy of one observed request.
pub const CapturedRequest = struct {
    allocator: Allocator,
    method: common.Method,
    path: []u8,
    query: []u8,
    headers: []common.Header,
    body: []u8,
    /// Full body length before the capture limit was applied.
    bodySize: usize,
    bodyTruncated: bool,
    headersTruncated: bool,

    pub fn deinit(self: *CapturedRequest) void {
        self.allocator.free(self.path);
        self.allocator.free(self.query);
        common.freeHeaders(self.allocator, self.headers);
        self.allocator.free(self.body);
        self.* = undefined;
    }

    /// Case-insensitive header lookup.
    pub fn header(self: *const CapturedRequest, name: []const u8) ?[]const u8 {
        return common.headerValue(self.headers, name);
    }

    /// True when the request body exceeded the capture budget.
    pub fn isBodyTruncated(self: *const CapturedRequest) bool {
        return self.bodyTruncated;
    }
};

/// Releases a snapshot slice returned by `Capture.snapshot`.
pub fn freeCaptured(allocator: Allocator, requests: []CapturedRequest) void {
    for (requests) |*r| r.deinit();
    allocator.free(requests);
}

pub const Capture = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    config: CaptureConfig,
    total: std.atomic.Value(usize) = .init(0),
    ring: []CapturedRequest = &.{},
    head: usize = 0,
    len: usize = 0,

    pub fn init(allocator: Allocator, io: std.Io, config: CaptureConfig) !Capture {
        return .{ .allocator = allocator, .io = io, .config = try validate(config) };
    }

    pub fn deinit(self: *Capture) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLocked();
        if (self.ring.len > 0) self.allocator.free(self.ring);
        self.ring = &.{};
    }

    pub fn totalCount(self: *const Capture) usize {
        return self.total.load(.acquire);
    }

    /// Number of currently retained requests.
    pub fn retainedCount(self: *Capture) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len;
    }

    /// Changes limits. Retained requests are dropped because the retention
    /// buffer may change size; the total counter is preserved.
    pub fn reconfigure(self: *Capture, config: CaptureConfig) !void {
        const checked = try validate(config);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLocked();
        if (self.ring.len > 0) {
            self.allocator.free(self.ring);
            self.ring = &.{};
        }
        self.config = checked;
    }

    /// Drops retained requests and resets the total counter.
    pub fn reset(self: *Capture) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLocked();
        self.total.store(0, .release);
    }

    fn clearLocked(self: *Capture) void {
        for (0..self.len) |i| {
            const entry = &self.ring[(self.head + i) % self.ring.len];
            entry.deinit();
        }
        self.head = 0;
        self.len = 0;
    }

    fn ensureRingLocked(self: *Capture) !void {
        if (self.config.maxEntries == 0) return;
        if (self.ring.len == self.config.maxEntries) return;
        if (self.ring.len > 0) {
            self.clearLocked();
            self.allocator.free(self.ring);
            self.ring = &.{};
        }
        self.head = 0;
        self.len = 0;
        self.ring = try self.allocator.alloc(CapturedRequest, self.config.maxEntries);
    }

    /// Observer callback target. Never fails the request: capture problems
    /// only reduce what tests can inspect.
    pub fn record(self: *Capture, ctx: *const common.Context) void {
        _ = self.total.fetchAdd(1, .monotonic);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.config.enabled or self.config.maxEntries == 0) return;

        self.ensureRingLocked() catch return;

        const entry = cloneContext(self.allocator, ctx, self.config) catch return;
        const index = (self.head + self.len) % self.ring.len;
        if (self.len == self.ring.len) {
            self.ring[self.head].deinit();
            self.head = (self.head + 1) % self.ring.len;
        } else {
            self.len += 1;
        }
        self.ring[index] = entry;
    }

    /// Copies retained requests oldest-first. Caller frees with
    /// `freeCaptured`.
    pub fn snapshot(self: *Capture, allocator: Allocator) ![]CapturedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = try allocator.alloc(CapturedRequest, self.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*r| r.deinit();
            allocator.free(out);
        }
        for (0..self.len) |i| {
            const source = &self.ring[(self.head + i) % self.ring.len];
            out[i] = try cloneEntry(allocator, source);
            built += 1;
        }
        return out;
    }

    /// Copies the most recent retained request, if any.
    pub fn last(self: *Capture, allocator: Allocator) !?CapturedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.len == 0) return null;
        const index = (self.head + self.len - 1) % self.ring.len;
        return try cloneEntry(allocator, &self.ring[index]);
    }
};

fn cloneContext(allocator: Allocator, ctx: *const common.Context, config: CaptureConfig) !CapturedRequest {
    const path = try allocator.dupe(u8, ctx.path);
    errdefer allocator.free(path);
    const query = try allocator.dupe(u8, ctx.query);
    errdefer allocator.free(query);

    var headerBudget = config.maxHeader;
    var headersTruncated = false;
    var headerList = std.ArrayList(common.Header).empty;
    errdefer {
        for (headerList.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headerList.deinit(allocator);
    }
    for (ctx.headers) |h| {
        const cost = h.name.len + h.value.len;
        if (cost > headerBudget) {
            headersTruncated = true;
            break;
        }
        headerBudget -= cost;
        const name = try allocator.dupe(u8, h.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, h.value);
        errdefer allocator.free(value);
        try headerList.append(allocator, .{ .name = name, .value = value });
    }
    const headers = try headerList.toOwnedSlice(allocator);
    errdefer common.freeHeaders(allocator, headers);

    const bodyLen = @min(ctx.body.len, config.maxBody);
    const body = try allocator.dupe(u8, ctx.body[0..bodyLen]);
    errdefer allocator.free(body);

    return .{
        .allocator = allocator,
        .method = ctx.method,
        .path = path,
        .query = query,
        .headers = headers,
        .body = body,
        .bodySize = ctx.body.len,
        .bodyTruncated = bodyLen < ctx.body.len,
        .headersTruncated = headersTruncated,
    };
}

fn cloneEntry(allocator: Allocator, source: *const CapturedRequest) !CapturedRequest {
    const path = try allocator.dupe(u8, source.path);
    errdefer allocator.free(path);
    const query = try allocator.dupe(u8, source.query);
    errdefer allocator.free(query);
    const headers = try common.dupeHeaders(allocator, source.headers);
    errdefer common.freeHeaders(allocator, headers);
    const body = try allocator.dupe(u8, source.body);
    errdefer allocator.free(body);
    return .{
        .allocator = allocator,
        .method = source.method,
        .path = path,
        .query = query,
        .headers = headers,
        .body = body,
        .bodySize = source.bodySize,
        .bodyTruncated = source.bodyTruncated,
        .headersTruncated = source.headersTruncated,
    };
}

test "capture headers are bounded and can be disabled" {
    const allocator = std.testing.allocator;
    var capture = try Capture.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .maxHeader = 8,
    });
    defer capture.deinit();

    const headers = [_]common.Header{
        .{ .name = "x-one", .value = "1" },
        .{ .name = "x-two", .value = "22" },
        .{ .name = "x-three", .value = "333" },
    };
    var ctx = common.Context{ .path = "/headers", .headers = &headers };
    capture.record(&ctx);
    var last = (try capture.last(allocator)).?;
    defer last.deinit();
    try std.testing.expectEqual(@as(usize, 1), last.headers.len);
    try std.testing.expect(last.headersTruncated);

    try capture.reconfigure(.{ .enabled = false });
    capture.record(&ctx);
    try std.testing.expectEqual(@as(usize, 2), capture.totalCount());
    try std.testing.expectEqual(@as(usize, 0), capture.retainedCount());

    capture.reset();
    try std.testing.expectEqual(@as(usize, 0), capture.totalCount());
}

test "capture copies requests, bounds bodies, and evicts oldest" {
    const allocator = std.testing.allocator;
    var capture = try Capture.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{ .maxEntries = 2, .maxBody = 4 });
    defer capture.deinit();

    const headers = [_]common.Header{.{ .name = "x-test", .value = "one" }};
    var ctx1 = common.Context{ .path = "/a", .query = "x=1", .headers = &headers, .body = "abcdef" };
    var ctx2 = common.Context{ .path = "/b", .method = .POST, .body = "ok" };
    var ctx3 = common.Context{ .path = "/c", .method = .DELETE };
    capture.record(&ctx1);
    capture.record(&ctx2);
    capture.record(&ctx3);

    try std.testing.expectEqual(@as(usize, 3), capture.totalCount());
    try std.testing.expectEqual(@as(usize, 2), capture.retainedCount());

    const all = try capture.snapshot(allocator);
    defer freeCaptured(allocator, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("/b", all[0].path);
    try std.testing.expectEqualStrings("/c", all[1].path);
    try std.testing.expectEqual(common.Method.DELETE, all[1].method);

    var last = (try capture.last(allocator)).?;
    defer last.deinit();
    try std.testing.expectEqualStrings("/c", last.path);

    // Re-record /a and verify body truncation bookkeeping.
    capture.record(&ctx1);
    var latest = (try capture.last(allocator)).?;
    defer latest.deinit();
    try std.testing.expectEqualStrings("/a", latest.path);
    try std.testing.expectEqual(@as(usize, 6), latest.bodySize);
    try std.testing.expectEqual(@as(usize, 4), latest.body.len);
    try std.testing.expect(latest.bodyTruncated);
    try std.testing.expectEqualStrings("one", latest.header("X-Test").?);
    try std.testing.expectEqualStrings("x=1", latest.query);
}
