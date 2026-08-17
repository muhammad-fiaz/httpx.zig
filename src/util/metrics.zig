//! Metrics and Observability for httpx.zig
//!
//! Provides lightweight, allocation-free request/response metrics collection.
//!
//! ## Metrics collected
//! - Total requests and responses
//! - Per-status-class counters (2xx, 3xx, 4xx, 5xx)
//! - Total bytes sent/received
//! - Active connection count
//! - Error count
//! - Latency tracking (min/max/total for avg)
//!
//! ## Usage
//! ```zig
//! var metrics = httpx.Metrics.init();
//! metrics.recordRequest();
//! metrics.recordResponse(200, 512, 1234); // status, bytes, latency_ns
//! const snapshot = metrics.snapshot();
//! std.debug.print("requests={d} avg_latency={d}ns\n", .{
//!     snapshot.total_requests, snapshot.avg_latency_ns,
//! });
//! ```

const std = @import("std");
const Atomic = std.atomic.Value;
const dbg = @import("debug.zig");

/// Event payload for metrics callbacks.
pub const MetricsEvent = union(enum) {
    request: void,
    response: struct {
        status: u16,
        bytes: u64,
        latency_ns: u64,
    },
    bytes_sent: u64,
    err: void,
    connection_open: void,
    connection_close: void,
};

/// Function pointer type for registering custom services callback logic.
pub const MetricsCallbackFn = *const fn (event: MetricsEvent) void;

/// Thread-safe metrics registry using atomic operations.
pub const Metrics = struct {
    total_requests: Atomic(u64) = .init(0),
    total_responses: Atomic(u64) = .init(0),
    active_connections: Atomic(i64) = .init(0),
    errors: Atomic(u64) = .init(0),
    bytes_sent: Atomic(u64) = .init(0),
    bytes_received: Atomic(u64) = .init(0),

    // Status class counters
    responses_2xx: Atomic(u64) = .init(0),
    responses_3xx: Atomic(u64) = .init(0),
    responses_4xx: Atomic(u64) = .init(0),
    responses_5xx: Atomic(u64) = .init(0),

    // Latency tracking (nanoseconds)
    latency_total_ns: Atomic(u64) = .init(0),
    latency_min_ns: Atomic(u64) = .init(std.math.maxInt(u64)),
    latency_max_ns: Atomic(u64) = .init(0),

    /// Optional callback for custom metrics hooks or integrations
    callback: ?MetricsCallbackFn = null,

    const Self = @This();

    /// Creates a zeroed Metrics instance.
    pub fn init() Self {
        return .{};
    }

    /// Creates a Metrics instance with a custom callback integration.
    pub fn initWithCallback(callback: MetricsCallbackFn) Self {
        return .{
            .callback = callback,
        };
    }

    /// Records an outgoing request.
    pub fn recordRequest(self: *Self) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        if (self.callback) |cb| cb(.{ .request = {} });
    }

    /// Records a received response with status code, bytes received, and latency.
    pub fn recordResponse(self: *Self, status: u16, bytes: u64, latency_ns: u64) void {
        dbg.entry("METRIC", "recordResponse");
        _ = self.total_responses.fetchAdd(1, .monotonic);
        _ = self.bytes_received.fetchAdd(bytes, .monotonic);

        const class = status / 100;
        switch (class) {
            2 => _ = self.responses_2xx.fetchAdd(1, .monotonic),
            3 => _ = self.responses_3xx.fetchAdd(1, .monotonic),
            4 => _ = self.responses_4xx.fetchAdd(1, .monotonic),
            5 => _ = self.responses_5xx.fetchAdd(1, .monotonic),
            else => {},
        }

        _ = self.latency_total_ns.fetchAdd(latency_ns, .monotonic);
        // Update min (relaxed -- best effort, not strictly atomic min)
        const old_min = self.latency_min_ns.load(.monotonic);
        if (latency_ns < old_min) {
            _ = self.latency_min_ns.cmpxchgWeak(old_min, latency_ns, .monotonic, .monotonic);
        }
        // Update max
        const old_max = self.latency_max_ns.load(.monotonic);
        if (latency_ns > old_max) {
            _ = self.latency_max_ns.cmpxchgWeak(old_max, latency_ns, .monotonic, .monotonic);
        }

        if (self.callback) |cb| cb(.{ .response = .{ .status = status, .bytes = bytes, .latency_ns = latency_ns } });
        dbg.exit("METRIC", "recordResponse");
    }

    /// Records bytes sent.
    pub fn recordBytesSent(self: *Self, bytes: u64) void {
        _ = self.bytes_sent.fetchAdd(bytes, .monotonic);
        if (self.callback) |cb| cb(.{ .bytes_sent = bytes });
    }

    /// Records an error.
    pub fn recordError(self: *Self) void {
        _ = self.errors.fetchAdd(1, .monotonic);
        if (self.callback) |cb| cb(.{ .err = {} });
    }

    /// Called when a new connection is established.
    pub fn connectionOpened(self: *Self) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
        if (self.callback) |cb| cb(.{ .connection_open = {} });
    }

    /// Called when a connection is closed.
    pub fn connectionClosed(self: *Self) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
        if (self.callback) |cb| cb(.{ .connection_close = {} });
    }

    /// Resets all counters to zero.
    pub fn reset(self: *Self) void {
        self.total_requests.store(0, .monotonic);
        self.total_responses.store(0, .monotonic);
        self.active_connections.store(0, .monotonic);
        self.errors.store(0, .monotonic);
        self.bytes_sent.store(0, .monotonic);
        self.bytes_received.store(0, .monotonic);
        self.responses_2xx.store(0, .monotonic);
        self.responses_3xx.store(0, .monotonic);
        self.responses_4xx.store(0, .monotonic);
        self.responses_5xx.store(0, .monotonic);
        self.latency_total_ns.store(0, .monotonic);
        self.latency_min_ns.store(std.math.maxInt(u64), .monotonic);
        self.latency_max_ns.store(0, .monotonic);
    }

    /// Returns a point-in-time snapshot of all metrics.
    pub fn snapshot(self: *const Self) MetricsSnapshot {
        const total = self.total_responses.load(.monotonic);
        const lat_total = self.latency_total_ns.load(.monotonic);
        const avg_lat: u64 = if (total > 0) lat_total / total else 0;
        const min_lat = self.latency_min_ns.load(.monotonic);

        return .{
            .total_requests = self.total_requests.load(.monotonic),
            .total_responses = total,
            .active_connections = self.active_connections.load(.monotonic),
            .total_errors = self.errors.load(.monotonic),
            .bytes_sent = self.bytes_sent.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .responses_2xx = self.responses_2xx.load(.monotonic),
            .responses_3xx = self.responses_3xx.load(.monotonic),
            .responses_4xx = self.responses_4xx.load(.monotonic),
            .responses_5xx = self.responses_5xx.load(.monotonic),
            .avg_latency_ns = avg_lat,
            .min_latency_ns = if (min_lat == std.math.maxInt(u64)) 0 else min_lat,
            .max_latency_ns = self.latency_max_ns.load(.monotonic),
        };
    }
};

/// Point-in-time metrics snapshot (non-atomic, copyable).
/// All values are returned via fields and getters. No internal printing.
pub const MetricsSnapshot = struct {
    total_requests: u64,
    total_responses: u64,
    active_connections: i64,
    total_errors: u64,
    bytes_sent: u64,
    bytes_received: u64,
    responses_2xx: u64,
    responses_3xx: u64,
    responses_4xx: u64,
    responses_5xx: u64,
    avg_latency_ns: u64,
    min_latency_ns: u64,
    max_latency_ns: u64,

    pub fn totalRequests(self: *const MetricsSnapshot) u64 {
        return self.total_requests;
    }

    pub fn totalResponses(self: *const MetricsSnapshot) u64 {
        return self.total_responses;
    }

    pub fn activeConnections(self: *const MetricsSnapshot) i64 {
        return self.active_connections;
    }

    pub fn errors(self: *const MetricsSnapshot) u64 {
        return self.total_errors;
    }

    pub fn bytesSent(self: *const MetricsSnapshot) u64 {
        return self.bytes_sent;
    }

    pub fn bytesReceived(self: *const MetricsSnapshot) u64 {
        return self.bytes_received;
    }

    pub fn responses2xx(self: *const MetricsSnapshot) u64 {
        return self.responses_2xx;
    }

    pub fn responses3xx(self: *const MetricsSnapshot) u64 {
        return self.responses_3xx;
    }

    pub fn responses4xx(self: *const MetricsSnapshot) u64 {
        return self.responses_4xx;
    }

    pub fn responses5xx(self: *const MetricsSnapshot) u64 {
        return self.responses_5xx;
    }

    pub fn avgLatencyNs(self: *const MetricsSnapshot) u64 {
        return self.avg_latency_ns;
    }

    pub fn minLatencyNs(self: *const MetricsSnapshot) u64 {
        return self.min_latency_ns;
    }

    pub fn maxLatencyNs(self: *const MetricsSnapshot) u64 {
        return self.max_latency_ns;
    }

    pub fn errorRate(self: *const MetricsSnapshot) f64 {
        if (self.total_requests == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_errors)) / @as(f64, @floatFromInt(self.total_requests));
    }

    pub fn successRate(self: *const MetricsSnapshot) f64 {
        if (self.total_responses == 0) return 0.0;
        return @as(f64, @floatFromInt(self.responses_2xx)) / @as(f64, @floatFromInt(self.total_responses));
    }

    pub fn redirectRate(self: *const MetricsSnapshot) f64 {
        if (self.total_responses == 0) return 0.0;
        return @as(f64, @floatFromInt(self.responses_3xx)) / @as(f64, @floatFromInt(self.total_responses));
    }

    pub fn clientErrorRate(self: *const MetricsSnapshot) f64 {
        if (self.total_responses == 0) return 0.0;
        return @as(f64, @floatFromInt(self.responses_4xx)) / @as(f64, @floatFromInt(self.total_responses));
    }

    pub fn serverErrorRate(self: *const MetricsSnapshot) f64 {
        if (self.total_responses == 0) return 0.0;
        return @as(f64, @floatFromInt(self.responses_5xx)) / @as(f64, @floatFromInt(self.total_responses));
    }

    pub fn throughputBytesPerResponse(self: *const MetricsSnapshot) u64 {
        if (self.total_responses == 0) return 0;
        return self.bytes_received / self.total_responses;
    }
};

test "Metrics basic operations" {
    var m = Metrics.init();
    m.recordRequest();
    m.recordRequest();
    m.recordResponse(200, 512, 1000);
    m.recordResponse(404, 128, 500);
    m.recordError();
    m.connectionOpened();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.total_requests);
    try std.testing.expectEqual(@as(u64, 2), snap.total_responses);
    try std.testing.expectEqual(@as(u64, 1), snap.responses_2xx);
    try std.testing.expectEqual(@as(u64, 1), snap.responses_4xx);
    try std.testing.expectEqual(@as(u64, 1), snap.total_errors);
    try std.testing.expectEqual(@as(i64, 1), snap.active_connections);
    try std.testing.expectEqual(@as(u64, 640), snap.bytes_received);
    try std.testing.expectEqual(@as(u64, 750), snap.avg_latency_ns);
    try std.testing.expectEqual(@as(u64, 500), snap.min_latency_ns);
    try std.testing.expectEqual(@as(u64, 1000), snap.max_latency_ns);
}

test "Metrics reset" {
    var m = Metrics.init();
    m.recordRequest();
    m.recordResponse(200, 1024, 5000);
    m.reset();
    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 0), snap.total_requests);
    try std.testing.expectEqual(@as(u64, 0), snap.total_responses);
}

const TestCallbackHelper = struct {
    var request_count: usize = 0;
    var last_status: u16 = 0;

    fn callback(event: MetricsEvent) void {
        switch (event) {
            .request => request_count += 1,
            .response => |r| last_status = r.status,
            else => {},
        }
    }
};

test "Metrics callbacks" {
    TestCallbackHelper.request_count = 0;
    TestCallbackHelper.last_status = 0;

    var m = Metrics.initWithCallback(TestCallbackHelper.callback);
    m.recordRequest();
    m.recordResponse(201, 100, 500);

    try std.testing.expectEqual(@as(usize, 1), TestCallbackHelper.request_count);
    try std.testing.expectEqual(@as(u16, 201), TestCallbackHelper.last_status);
}
