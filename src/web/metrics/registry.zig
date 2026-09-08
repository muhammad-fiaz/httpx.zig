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
    val: std.atomic.Value(u64) = .init(0),

    pub fn init(initial: u64) Counter {
        return .{ .val = .init(initial) };
    }

    pub fn inc(self: *Counter) void {
        _ = self.val.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, n: u64) void {
        _ = self.val.fetchAdd(n, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.val.load(.monotonic);
    }

    pub fn load(self: *const Counter, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.val.load(ordering);
    }

    pub fn fetchAdd(self: *Counter, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.val.fetchAdd(val, ordering);
    }

    pub fn reset(self: *Counter) void {
        self.val.store(0, .monotonic);
    }
};

/// Underflow-safe atomic gauge.
pub const Gauge = struct {
    val: std.atomic.Value(u64) = .init(0),

    pub fn init(initial: u64) Gauge {
        return .{ .val = .init(initial) };
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
        _ = self.val.fetchAdd(n, .monotonic);
    }

    pub fn sub(self: *Gauge, n: u64) void {
        while (true) {
            const current = self.val.load(.monotonic);
            const next = if (current >= n) current - n else 0;
            if (self.val.cmpxchgWeak(current, next, .monotonic, .monotonic) == null) break;
        }
    }

    pub fn set(self: *Gauge, n: u64) void {
        self.val.store(n, .monotonic);
    }

    pub fn store(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) void {
        self.val.store(val, ordering);
    }

    pub fn get(self: *const Gauge) u64 {
        return self.val.load(.monotonic);
    }

    pub fn load(self: *const Gauge, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.val.load(ordering);
    }

    pub fn fetchAdd(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.val.fetchAdd(val, ordering);
    }

    pub fn fetchSub(self: *Gauge, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        _ = ordering;
        while (true) {
            const current = self.val.load(.monotonic);
            const next = if (current >= val) current - val else 0;
            if (self.val.cmpxchgWeak(current, next, .monotonic, .monotonic) == null) return current;
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
    sum_nanos: Counter = .{},

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
        self.sum_nanos.add(ns);
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
        return @as(f64, @floatFromInt(self.sum_nanos.get())) / 1_000_000_000.0;
    }

    pub fn getBucketCount(self: *const Histogram, idx: usize) u64 {
        if (idx >= LATENCY_BUCKET_COUNT) return self.count.get();
        return self.buckets[idx].get();
    }

    pub fn reset(self: *Histogram) void {
        for (&self.buckets) |*b| b.reset();
        self.count.reset();
        self.sum_nanos.reset();
    }
};

/// High-performance thread-safe HTTP metrics registry.
pub const Registry = struct {
    requests_total: Counter = .{},
    responses_total: Counter = .{},
    errors_total: Counter = .{},
    timeouts_total: Counter = .{},
    bytes_in: Counter = .{},
    bytes_out: Counter = .{},
    active_connections: Gauge = .{},
    active_requests: Gauge = .{},

    // Status classes
    status_2xx: Counter = .{},
    status_3xx: Counter = .{},
    status_4xx: Counter = .{},
    status_5xx: Counter = .{},

    // Methods
    method_get: Counter = .{},
    method_post: Counter = .{},
    method_put: Counter = .{},
    method_delete: Counter = .{},
    method_patch: Counter = .{},
    method_head: Counter = .{},
    method_options: Counter = .{},
    method_other: Counter = .{},

    // Latency
    request_duration: Histogram = .{},

    pub fn recordRequest(self: *Registry) void {
        self.requests_total.inc();
        self.active_requests.inc();
    }

    pub fn recordRequestMethod(self: *Registry, method: []const u8) void {
        if (std.ascii.eqlIgnoreCase(method, "GET")) {
            self.method_get.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "POST")) {
            self.method_post.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "PUT")) {
            self.method_put.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "DELETE")) {
            self.method_delete.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "PATCH")) {
            self.method_patch.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "HEAD")) {
            self.method_head.inc();
        } else if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
            self.method_options.inc();
        } else {
            self.method_other.inc();
        }
    }

    pub fn recordResponse(self: *Registry, bytes_written: u64) void {
        self.responses_total.inc();
        self.active_requests.dec();
        self.bytes_out.add(bytes_written);
    }

    pub fn recordResponseFull(self: *Registry, status: u16, duration_ns: u64, bytes_written: u64) void {
        self.recordResponse(bytes_written);
        self.recordStatus(status);
        self.request_duration.observeNanos(duration_ns);
    }

    pub fn recordStatus(self: *Registry, status_code: u16) void {
        if (status_code >= 200 and status_code < 300) {
            self.status_2xx.inc();
        } else if (status_code >= 300 and status_code < 400) {
            self.status_3xx.inc();
        } else if (status_code >= 400 and status_code < 500) {
            self.status_4xx.inc();
        } else if (status_code >= 500 and status_code < 600) {
            self.status_5xx.inc();
        }
    }

    pub fn recordError(self: *Registry) void {
        self.errors_total.inc();
        self.active_requests.dec();
    }

    pub fn recordBytesIn(self: *Registry, n: u64) void {
        self.bytes_in.add(n);
    }

    pub fn recordBytesOut(self: *Registry, n: u64) void {
        self.bytes_out.add(n);
    }

    pub fn recordTimeout(self: *Registry) void {
        self.timeouts_total.inc();
    }

    pub fn connectionOpened(self: *Registry) void {
        self.active_connections.inc();
    }

    pub fn connectionClosed(self: *Registry) void {
        self.active_connections.dec();
    }

    /// Captures a point-in-time immutable snapshot of all metrics.
    pub fn snapshot(self: *const Registry) MetricsSnapshot {
        var snap: MetricsSnapshot = .{
            .requests_total = self.requests_total.get(),
            .responses_total = self.responses_total.get(),
            .errors_total = self.errors_total.get(),
            .timeouts_total = self.timeouts_total.get(),
            .bytes_in = self.bytes_in.get(),
            .bytes_out = self.bytes_out.get(),
            .active_connections = self.active_connections.get(),
            .active_requests = self.active_requests.get(),

            .status_2xx = self.status_2xx.get(),
            .status_3xx = self.status_3xx.get(),
            .status_4xx = self.status_4xx.get(),
            .status_5xx = self.status_5xx.get(),

            .method_get = self.method_get.get(),
            .method_post = self.method_post.get(),
            .method_put = self.method_put.get(),
            .method_delete = self.method_delete.get(),
            .method_patch = self.method_patch.get(),
            .method_head = self.method_head.get(),
            .method_options = self.method_options.get(),
            .method_other = self.method_other.get(),

            .duration_count = self.request_duration.getCount(),
            .duration_sum_seconds = self.request_duration.getSumSeconds(),
        };
        for (0..LATENCY_BUCKET_COUNT) |i| {
            snap.duration_buckets[i] = self.request_duration.getBucketCount(i);
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
        try emitCounter(w, "http_requests_total", "Total HTTP requests received", self.requests_total.get());
        try emitCounter(w, "http_responses_total", "Total HTTP responses sent", self.responses_total.get());
        try emitCounter(w, "http_errors_total", "Total HTTP errors encountered", self.errors_total.get());
        try emitCounter(w, "http_timeouts_total", "Total request timeouts", self.timeouts_total.get());
        try emitCounter(w, "http_bytes_in_total", "Total bytes received", self.bytes_in.get());
        try emitCounter(w, "http_bytes_out_total", "Total bytes sent", self.bytes_out.get());

        // Gauges
        try emitGauge(w, "http_active_connections", "Number of currently active connections", self.active_connections.get());
        try emitGauge(w, "http_active_requests", "Number of currently in-flight requests", self.active_requests.get());

        // Method Breakdown
        try w.print("# HELP http_requests_by_method_total Total HTTP requests by method\n# TYPE http_requests_by_method_total counter\n", .{});
        try w.print("http_requests_by_method_total{{method=\"GET\"}} {d}\n", .{self.method_get.get()});
        try w.print("http_requests_by_method_total{{method=\"POST\"}} {d}\n", .{self.method_post.get()});
        try w.print("http_requests_by_method_total{{method=\"PUT\"}} {d}\n", .{self.method_put.get()});
        try w.print("http_requests_by_method_total{{method=\"DELETE\"}} {d}\n", .{self.method_delete.get()});
        try w.print("http_requests_by_method_total{{method=\"PATCH\"}} {d}\n", .{self.method_patch.get()});
        try w.print("http_requests_by_method_total{{method=\"HEAD\"}} {d}\n", .{self.method_head.get()});
        try w.print("http_requests_by_method_total{{method=\"OPTIONS\"}} {d}\n", .{self.method_options.get()});
        try w.print("http_requests_by_method_total{{method=\"other\"}} {d}\n", .{self.method_other.get()});

        // Status Class Breakdown
        try w.print("# HELP http_responses_by_status_total Total HTTP responses by status class\n# TYPE http_responses_by_status_total counter\n", .{});
        try w.print("http_responses_by_status_total{{status=\"2xx\"}} {d}\n", .{self.status_2xx.get()});
        try w.print("http_responses_by_status_total{{status=\"3xx\"}} {d}\n", .{self.status_3xx.get()});
        try w.print("http_responses_by_status_total{{status=\"4xx\"}} {d}\n", .{self.status_4xx.get()});
        try w.print("http_responses_by_status_total{{status=\"5xx\"}} {d}\n", .{self.status_5xx.get()});

        // Latency Histogram
        try w.print("# HELP http_request_duration_seconds HTTP request duration in seconds\n# TYPE http_request_duration_seconds histogram\n", .{});
        inline for (LATENCY_BUCKET_LABELS, 0..) |lbl, i| {
            try w.print("http_request_duration_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ lbl, self.request_duration.getBucketCount(i) });
        }
        try w.print("http_request_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{self.request_duration.getCount()});
        try w.print("http_request_duration_seconds_sum {d:.6}\n", .{self.request_duration.getSumSeconds()});
        try w.print("http_request_duration_seconds_count {d}\n", .{self.request_duration.getCount()});
    }

    fn emitCounter(w: anytype, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} counter\n{s} {d}\n", .{ name, help, name, name, v });
    }

    fn emitGauge(w: anytype, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} gauge\n{s} {d}\n", .{ name, help, name, name, v });
    }

    pub fn reset(self: *Registry) void {
        self.requests_total.reset();
        self.responses_total.reset();
        self.errors_total.reset();
        self.timeouts_total.reset();
        self.bytes_in.reset();
        self.bytes_out.reset();
        self.active_connections.reset();
        self.active_requests.reset();

        self.status_2xx.reset();
        self.status_3xx.reset();
        self.status_4xx.reset();
        self.status_5xx.reset();

        self.method_get.reset();
        self.method_post.reset();
        self.method_put.reset();
        self.method_delete.reset();
        self.method_patch.reset();
        self.method_head.reset();
        self.method_options.reset();
        self.method_other.reset();

        self.request_duration.reset();
    }
};

test "registry counters and backwards compatibility" {
    var r = Registry{};
    r.recordRequest();
    r.recordRequest();
    r.recordResponse(100);
    try std.testing.expectEqual(@as(u64, 2), r.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.responses_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.active_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), r.bytes_out.load(.monotonic));
}

test "connection open and close with underflow protection" {
    var r = Registry{};
    r.connectionOpened();
    r.connectionOpened();
    try std.testing.expectEqual(@as(u64, 2), r.active_connections.load(.monotonic));
    r.connectionClosed();
    try std.testing.expectEqual(@as(u64, 1), r.active_connections.load(.monotonic));
    r.connectionClosed();
    r.connectionClosed(); // underflow safe
    try std.testing.expectEqual(@as(u64, 0), r.active_connections.load(.monotonic));
}

test "status and method tracking" {
    var r = Registry{};
    r.recordRequestMethod("GET");
    r.recordRequestMethod("POST");
    r.recordStatus(200);
    r.recordStatus(201);
    r.recordStatus(404);
    r.recordStatus(500);

    try std.testing.expectEqual(@as(u64, 1), r.method_get.get());
    try std.testing.expectEqual(@as(u64, 1), r.method_post.get());
    try std.testing.expectEqual(@as(u64, 0), r.method_delete.get());
    try std.testing.expectEqual(@as(u64, 2), r.status_2xx.get());
    try std.testing.expectEqual(@as(u64, 1), r.status_4xx.get());
    try std.testing.expectEqual(@as(u64, 1), r.status_5xx.get());
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
    try std.testing.expectEqual(@as(u64, 1), snap.requests_total);
    try std.testing.expectEqual(@as(u64, 1), snap.responses_total);
    try std.testing.expectEqual(@as(u64, 1), snap.method_get);
    try std.testing.expectEqual(@as(u64, 1), snap.status_2xx);
    try std.testing.expectEqual(@as(u64, 512), snap.bytes_out);
    try std.testing.expectEqual(@as(u64, 1), snap.duration_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), snap.duration_sum_seconds, 0.001);

    // Further changes do not alter snap
    r.recordRequest();
    try std.testing.expectEqual(@as(u64, 1), snap.requests_total);
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
