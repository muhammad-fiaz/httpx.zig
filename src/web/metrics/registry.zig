//! Production metrics registry: atomics, latency histograms, and Prometheus text exposition.

const std = @import("std");
pub const snapshot_mod = @import("snapshot.zig");
pub const MetricsSnapshot = snapshot_mod.MetricsSnapshot;
pub const ServerSnapshot = snapshot_mod.ServerSnapshot;
pub const ClientSnapshot = snapshot_mod.ClientSnapshot;
pub const LATENCY_BUCKET_COUNT = snapshot_mod.LATENCY_BUCKET_COUNT;

/// Standard Prometheus latency bucket thresholds in seconds.
pub const LATENCY_BUCKETS = [LATENCY_BUCKET_COUNT]f64{
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
};

/// String representations for standard Prometheus `le` bucket labels.
pub const LATENCY_BUCKET_LABELS = [LATENCY_BUCKET_COUNT][]const u8{
    "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10",
};

/// Monotonically increasing atomic counter.
pub const Counter = struct {
    val: std.atomic.Value(usize) = .init(0),

    pub fn init(initial: u64) Counter {
        return .{ .val = .init(@intCast(initial)) };
    }

    pub fn inc(self: *Counter) void {
        _ = self.val.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, n: u64) void {
        _ = self.val.fetchAdd(@intCast(n), .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return @intCast(self.val.load(.monotonic));
    }

    pub fn load(self: *const Counter, comptime ordering: std.builtin.AtomicOrder) u64 {
        return @intCast(self.val.load(ordering));
    }

    pub fn fetchAdd(self: *Counter, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return @intCast(self.val.fetchAdd(@intCast(val), ordering));
    }

    pub fn reset(self: *Counter) void {
        self.val.store(0, .monotonic);
    }
};

/// Underflow-safe atomic gauge.
pub const Gauge = struct {
    val: std.atomic.Value(usize) = .init(0),

    pub fn init(initial: u64) Gauge {
        return .{ .val = .init(@intCast(initial)) };
    }

    pub fn inc(self: *Gauge) void {
        _ = self.val.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        while (true) {
            const current = self.val.load(.monotonic);
            if (current == 0) break;
            if (self.val.cmpxchgWeak(current, current - 1, .monotonic, .monotonic) == null) break;
        }
    }

    pub fn add(self: *Gauge, n: u64) void {
        _ = self.val.fetchAdd(@intCast(n), .monotonic);
    }

    pub fn sub(self: *Gauge, n: u64) void {
        while (true) {
            const current = self.val.load(.monotonic);
            const dec_by: usize = @intCast(n);
            const next = if (current >= dec_by) current - dec_by else 0;
            if (self.val.cmpxchgWeak(current, next, .monotonic, .monotonic) == null) break;
        }
    }

    pub fn set(self: *Gauge, n: u64) void {
        self.val.store(@intCast(n), .monotonic);
    }

    pub fn store(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) void {
        self.val.store(@intCast(val), ordering);
    }

    pub fn get(self: *const Gauge) u64 {
        return @intCast(self.val.load(.monotonic));
    }

    pub fn load(self: *const Gauge, comptime ordering: std.builtin.AtomicOrder) u64 {
        return @intCast(self.val.load(ordering));
    }

    pub fn fetchAdd(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return @intCast(self.val.fetchAdd(@intCast(val), ordering));
    }

    pub fn fetchSub(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        _ = ordering;
        while (true) {
            const current = self.val.load(.monotonic);
            const dec_by: usize = @intCast(val);
            const next = if (current >= dec_by) current - dec_by else 0;
            if (self.val.cmpxchgWeak(current, next, .monotonic, .monotonic) == null) return @intCast(current);
        }
    }

    pub fn reset(self: *Gauge) void {
        self.val.store(0, .monotonic);
    }
};

/// Thread-safe cumulative histogram for request latency distribution.
pub const Histogram = struct {
    buckets: [LATENCY_BUCKET_COUNT]Counter = [_]Counter{.{}} ** LATENCY_BUCKET_COUNT,
    count: Counter = .{},
    sumNanos: Counter = .{},

    /// Record a duration in seconds.
    pub fn observeSeconds(self: *Histogram, sec: f64) void {
        const ns: u64 = if (sec <= 0.0)
            0
        else
            @intFromFloat(@min(sec * 1_000_000_000.0, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
        self.observeNanos(ns);
    }

    /// Record a duration in milliseconds.
    pub fn observeMs(self: *Histogram, ms: f64) void {
        const ns: u64 = if (ms <= 0.0)
            0
        else
            @intFromFloat(@min(ms * 1_000_000.0, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
        self.observeNanos(ns);
    }

    /// Record a duration in nanoseconds.
    pub fn observeNanos(self: *Histogram, ns: u64) void {
        const sec = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
        self.count.inc();
        self.sumNanos.add(ns);
        inline for (LATENCY_BUCKETS, 0..) |bound, i| {
            if (sec <= bound) {
                self.buckets[i].inc();
            }
        }
    }

    pub fn getCount(self: *const Histogram) u64 {
        return self.count.get();
    }

    pub fn getSumSeconds(self: *const Histogram) f64 {
        return @as(f64, @floatFromInt(self.sumNanos.get())) / 1_000_000_000.0;
    }

    pub fn getBucketCount(self: *const Histogram, idx: usize) u64 {
        if (idx >= LATENCY_BUCKET_COUNT) return self.count.get();
        return self.buckets[idx].get();
    }

    pub fn reset(self: *Histogram) void {
        for (&self.buckets) |*b| b.reset();
        self.count.reset();
        self.sumNanos.reset();
    }
};

/// High-performance thread-safe HTTP metrics registry.
pub const Registry = struct {
    requestsTotal: Counter = .{},
    responsesTotal: Counter = .{},
    errorsTotal: Counter = .{},
    timeoutsTotal: Counter = .{},
    bytesIn: Counter = .{},
    bytesOut: Counter = .{},
    activeConnections: Gauge = .{},
    activeRequests: Gauge = .{},

    // Status classes
    status2xx: Counter = .{},
    status3xx: Counter = .{},
    status4xx: Counter = .{},
    status5xx: Counter = .{},

    // Methods
    methodGet: Counter = .{},
    methodPost: Counter = .{},
    methodPut: Counter = .{},
    methodDelete: Counter = .{},
    methodPatch: Counter = .{},
    methodHead: Counter = .{},
    methodOptions: Counter = .{},
    methodOther: Counter = .{},

    // Latency
    requestDuration: Histogram = .{},

    pub fn recordRequest(self: *Registry) void {
        self.requestsTotal.inc();
        self.activeRequests.inc();
    }

    pub fn recordRequestMethod(self: *Registry, method: []const u8) void {
        if (std.ascii.eqlIgnoreCase(method, "GET")) {
            self.methodGet.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "POST")) {
            self.methodPost.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "PUT")) {
            self.methodPut.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "DELETE")) {
            self.methodDelete.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "PATCH")) {
            self.methodPatch.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "HEAD")) {
            self.methodHead.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
            self.methodOptions.inc();
        } else {
            self.methodOther.inc();
        }
    }

    pub fn recordResponse(self: *Registry, bytes_written: u64) void {
        self.responsesTotal.inc();
        self.activeRequests.dec();
        self.bytesOut.add(bytes_written);
    }

    pub fn recordResponseFull(self: *Registry, status: u16, duration_ns: u64, bytes_written: u64) void {
        self.recordResponse(bytes_written);
        self.recordStatus(status);
        self.requestDuration.observeNanos(duration_ns);
    }

    pub fn recordStatus(self: *Registry, statusCode: u16) void {
        if (statusCode >= 200 and statusCode < 300) {
            self.status2xx.inc();
        } else if (statusCode >= 300 and statusCode < 400) {
            self.status3xx.inc();
        } else if (statusCode >= 400 and statusCode < 500) {
            self.status4xx.inc();
        } else if (statusCode >= 500 and statusCode < 600) {
            self.status5xx.inc();
        }
    }

    pub fn recordError(self: *Registry) void {
        self.errorsTotal.inc();
        self.activeRequests.dec();
    }

    pub fn recordBytesIn(self: *Registry, n: u64) void {
        self.bytesIn.add(n);
    }

    pub fn recordBytesOut(self: *Registry, n: u64) void {
        self.bytesOut.add(n);
    }

    pub fn recordTimeout(self: *Registry) void {
        self.timeoutsTotal.inc();
    }

    pub fn connectionOpened(self: *Registry) void {
        self.activeConnections.inc();
    }

    pub fn connectionClosed(self: *Registry) void {
        self.activeConnections.dec();
    }

    /// Captures a point-in-time immutable snapshot of all metrics.
    pub fn snapshot(self: *const Registry) MetricsSnapshot {
        var snap: MetricsSnapshot = .{
            .requestsTotal = self.requestsTotal.get(),
            .responsesTotal = self.responsesTotal.get(),
            .errorsTotal = self.errorsTotal.get(),
            .timeoutsTotal = self.timeoutsTotal.get(),
            .bytesIn = self.bytesIn.get(),
            .bytesOut = self.bytesOut.get(),
            .activeConnections = self.activeConnections.get(),
            .activeRequests = self.activeRequests.get(),

            .status2xx = self.status2xx.get(),
            .status3xx = self.status3xx.get(),
            .status4xx = self.status4xx.get(),
            .status5xx = self.status5xx.get(),

            .methodGet = self.methodGet.get(),
            .methodPost = self.methodPost.get(),
            .methodPut = self.methodPut.get(),
            .methodDelete = self.methodDelete.get(),
            .methodPatch = self.methodPatch.get(),
            .methodHead = self.methodHead.get(),
            .methodOptions = self.methodOptions.get(),
            .methodOther = self.methodOther.get(),

            .durationCount = self.requestDuration.getCount(),
            .durationSumSeconds = self.requestDuration.getSumSeconds(),
        };
        for (0..LATENCY_BUCKET_COUNT) |i| {
            snap.durationBuckets[i] = self.requestDuration.getBucketCount(i);
        }
        return snap;
    }

    /// Render Prometheus text format (version 0.0.4).
    pub fn render(self: *const Registry, w: anytype) !void {
        try self.renderPrometheus(w);
    }

    /// Render full production Prometheus text format with help strings, types, labels, and histogram.
    pub fn renderPrometheus(self: *const Registry, w: anytype) !void {
        // Base Counters
        try emitCounter(w, "http_requests_total", "Total HTTP requests received", self.requestsTotal.get());
        try emitCounter(w, "http_responses_total", "Total HTTP responses sent", self.responsesTotal.get());
        try emitCounter(w, "http_errors_total", "Total HTTP errors encountered", self.errorsTotal.get());
        try emitCounter(w, "http_timeouts_total", "Total request timeouts", self.timeoutsTotal.get());
        try emitCounter(w, "http_bytesIn_total", "Total bytes received", self.bytesIn.get());
        try emitCounter(w, "http_bytesOut_total", "Total bytes sent", self.bytesOut.get());

        // Gauges
        try emitGauge(w, "http_active_connections", "Number of currently active connections", self.activeConnections.get());
        try emitGauge(w, "http_active_requests", "Number of currently in-flight requests", self.activeRequests.get());

        // Method Breakdown
        try w.print("# HELP http_requests_by_method_total Total HTTP requests by method\n# TYPE http_requests_by_method_total counter\n", .{});
        try w.print("http_requests_by_method_total{{method=\"GET\"}} {d}\n", .{self.methodGet.get()});
        try w.print("http_requests_by_method_total{{method=\"POST\"}} {d}\n", .{self.methodPost.get()});
        try w.print("http_requests_by_method_total{{method=\"PUT\"}} {d}\n", .{self.methodPut.get()});
        try w.print("http_requests_by_method_total{{method=\"DELETE\"}} {d}\n", .{self.methodDelete.get()});
        try w.print("http_requests_by_method_total{{method=\"PATCH\"}} {d}\n", .{self.methodPatch.get()});
        try w.print("http_requests_by_method_total{{method=\"HEAD\"}} {d}\n", .{self.methodHead.get()});
        try w.print("http_requests_by_method_total{{method=\"OPTIONS\"}} {d}\n", .{self.methodOptions.get()});
        try w.print("http_requests_by_method_total{{method=\"other\"}} {d}\n", .{self.methodOther.get()});

        // Status Class Breakdown
        try w.print("# HELP http_responses_by_status_total Total HTTP responses by status class\n# TYPE http_responses_by_status_total counter\n", .{});
        try w.print("http_responses_by_status_total{{status=\"2xx\"}} {d}\n", .{self.status2xx.get()});
        try w.print("http_responses_by_status_total{{status=\"3xx\"}} {d}\n", .{self.status3xx.get()});
        try w.print("http_responses_by_status_total{{status=\"4xx\"}} {d}\n", .{self.status4xx.get()});
        try w.print("http_responses_by_status_total{{status=\"5xx\"}} {d}\n", .{self.status5xx.get()});

        // Latency Histogram
        try w.print("# HELP http_request_duration_seconds HTTP request duration in seconds\n# TYPE http_request_duration_seconds histogram\n", .{});
        inline for (LATENCY_BUCKET_LABELS, 0..) |lbl, i| {
            try w.print("http_request_duration_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ lbl, self.requestDuration.getBucketCount(i) });
        }
        try w.print("http_request_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{self.requestDuration.getCount()});
        try w.print("http_request_duration_seconds_sum {d:.6}\n", .{self.requestDuration.getSumSeconds()});
        try w.print("http_request_duration_seconds_count {d}\n", .{self.requestDuration.getCount()});
    }

    fn emitCounter(w: anytype, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} counter\n{s} {d}\n", .{ name, help, name, name, v });
    }

    fn emitGauge(w: anytype, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} gauge\n{s} {d}\n", .{ name, help, name, name, v });
    }

    pub fn reset(self: *Registry) void {
        self.requestsTotal.reset();
        self.responsesTotal.reset();
        self.errorsTotal.reset();
        self.timeoutsTotal.reset();
        self.bytesIn.reset();
        self.bytesOut.reset();
        self.activeConnections.reset();
        self.activeRequests.reset();

        self.status2xx.reset();
        self.status3xx.reset();
        self.status4xx.reset();
        self.status5xx.reset();

        self.methodGet.reset();
        self.methodPost.reset();
        self.methodPut.reset();
        self.methodDelete.reset();
        self.methodPatch.reset();
        self.methodHead.reset();
        self.methodOptions.reset();
        self.methodOther.reset();

        self.requestDuration.reset();
    }
};

test "registry counters and backwards compatibility" {
    var r = Registry{};
    r.recordRequest();
    r.recordRequest();
    r.recordResponse(100);
    try std.testing.expectEqual(@as(u64, 2), r.requestsTotal.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.responsesTotal.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.activeRequests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), r.bytesOut.load(.monotonic));
}

test "connection open and close with underflow protection" {
    var r = Registry{};
    r.connectionOpened();
    r.connectionOpened();
    try std.testing.expectEqual(@as(u64, 2), r.activeConnections.load(.monotonic));
    r.connectionClosed();
    try std.testing.expectEqual(@as(u64, 1), r.activeConnections.load(.monotonic));
    r.connectionClosed();
    r.connectionClosed(); // underflow safe
    try std.testing.expectEqual(@as(u64, 0), r.activeConnections.load(.monotonic));
}

test "status and method tracking" {
    var r = Registry{};
    r.recordRequestMethod("GET");
    r.recordRequestMethod("POST");
    r.recordStatus(200);
    r.recordStatus(201);
    r.recordStatus(404);
    r.recordStatus(500);

    try std.testing.expectEqual(@as(u64, 1), r.methodGet.get());
    try std.testing.expectEqual(@as(u64, 1), r.methodPost.get());
    try std.testing.expectEqual(@as(u64, 0), r.methodDelete.get());
    try std.testing.expectEqual(@as(u64, 2), r.status2xx.get());
    try std.testing.expectEqual(@as(u64, 1), r.status4xx.get());
    try std.testing.expectEqual(@as(u64, 1), r.status5xx.get());
}

test "histogram latency observation" {
    var h = Histogram{};
    h.observeSeconds(0.003); // fits in 0.005 and up
    h.observeSeconds(0.040); // fits in 0.05 and up
    h.observeSeconds(2.0); // fits in 2.5 and up

    try std.testing.expectEqual(@as(u64, 3), h.getCount());
    try std.testing.expectEqual(@as(u64, 1), h.getBucketCount(0)); // 0.005 bucket
    try std.testing.expectEqual(@as(u64, 2), h.getBucketCount(3)); // 0.05 bucket
    try std.testing.expectEqual(@as(u64, 3), h.getBucketCount(8)); // 2.5 bucket
    try std.testing.expect(h.getSumSeconds() > 2.0);
}

test "snapshot immutability" {
    var r = Registry{};
    r.recordRequest();
    r.recordRequestMethod("GET");
    r.recordResponseFull(200, 15_000_000, 512); // 15ms, 512 bytes

    const snap = r.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.requestsTotal);
    try std.testing.expectEqual(@as(u64, 1), snap.responsesTotal);
    try std.testing.expectEqual(@as(u64, 1), snap.methodGet);
    try std.testing.expectEqual(@as(u64, 1), snap.status2xx);
    try std.testing.expectEqual(@as(u64, 512), snap.bytesOut);
    try std.testing.expectEqual(@as(u64, 1), snap.durationCount);
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), snap.durationSumSeconds, 0.001);

    // Further changes do not alter snap
    r.recordRequest();
    try std.testing.expectEqual(@as(u64, 1), snap.requestsTotal);
}

test "prometheus text format rendering" {
    var r = Registry{};
    r.recordRequest();
    r.recordRequestMethod("GET");
    r.recordResponseFull(200, 5_000_000, 128); // 5ms

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&w);
    const out = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "http_requests_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# TYPE http_requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http_requests_by_method_total{method=\"GET\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http_responses_by_status_total{status=\"2xx\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http_request_duration_seconds_bucket{le=\"0.005\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http_request_duration_seconds_count 1") != null);
}
