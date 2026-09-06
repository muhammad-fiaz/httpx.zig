//! Metrics registry: atomic counters + Prometheus text exposition.

const std = @import("std");

pub const Registry = struct {
    requests_total: std.atomic.Value(u64) = .init(0),
    responses_total: std.atomic.Value(u64) = .init(0),
    errors_total: std.atomic.Value(u64) = .init(0),
    bytes_in: std.atomic.Value(u64) = .init(0),
    bytes_out: std.atomic.Value(u64) = .init(0),
    active_connections: std.atomic.Value(u64) = .init(0),
    active_requests: std.atomic.Value(u64) = .init(0),
    timeouts_total: std.atomic.Value(u64) = .init(0),

    pub fn recordRequest(self: *Registry) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
        _ = self.active_requests.fetchAdd(1, .monotonic);
    }

    pub fn recordResponse(self: *Registry, bytes_written: u64) void {
        _ = self.responses_total.fetchAdd(1, .monotonic);
        if (self.active_requests.load(.monotonic) > 0)
            _ = self.active_requests.fetchSub(1, .monotonic);
        _ = self.bytes_out.fetchAdd(bytes_written, .monotonic);
    }

    pub fn recordError(self: *Registry) void {
        _ = self.errors_total.fetchAdd(1, .monotonic);
        if (self.active_requests.load(.monotonic) > 0)
            _ = self.active_requests.fetchSub(1, .monotonic);
    }

    pub fn recordBytesIn(self: *Registry, n: u64) void {
        _ = self.bytes_in.fetchAdd(n, .monotonic);
    }

    pub fn recordTimeout(self: *Registry) void {
        _ = self.timeouts_total.fetchAdd(1, .monotonic);
    }

    pub fn connectionOpened(self: *Registry) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn connectionClosed(self: *Registry) void {
        if (self.active_connections.load(.monotonic) > 0)
            _ = self.active_connections.fetchSub(1, .monotonic);
    }

    /// Render Prometheus text format (version 0.0.4).
    pub fn render(self: *Registry, w: *std.Io.Writer) !void {
        try counter(w, "http_requests_total", "Total HTTP requests", self.requests_total.load(.monotonic));
        try counter(w, "http_responses_total", "Total HTTP responses", self.responses_total.load(.monotonic));
        try counter(w, "http_errors_total", "Total HTTP errors", self.errors_total.load(.monotonic));
        try counter(w, "http_timeouts_total", "Total timeouts", self.timeouts_total.load(.monotonic));
        try counter(w, "http_bytes_in_total", "Total bytes received", self.bytes_in.load(.monotonic));
        try counter(w, "http_bytes_out_total", "Total bytes sent", self.bytes_out.load(.monotonic));
        try gauge(w, "http_active_connections", "Active connections", self.active_connections.load(.monotonic));
        try gauge(w, "http_active_requests", "Active requests", self.active_requests.load(.monotonic));
    }

    fn counter(w: *std.Io.Writer, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} counter\n{s} {d}\n", .{ name, help, name, name, v });
    }

    fn gauge(w: *std.Io.Writer, name: []const u8, help: []const u8, v: u64) !void {
        try w.print("# HELP {s} {s}\n# TYPE {s} gauge\n{s} {d}\n", .{ name, help, name, name, v });
    }
};

test "registry counters" {
    var r = Registry{};
    r.recordRequest();
    r.recordRequest();
    r.recordResponse(100);
    try std.testing.expectEqual(@as(u64, 2), r.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.responses_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.active_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), r.bytes_out.load(.monotonic));
}

test "connection open/close" {
    var r = Registry{};
    r.connectionOpened();
    r.connectionOpened();
    try std.testing.expectEqual(@as(u64, 2), r.active_connections.load(.monotonic));
    r.connectionClosed();
    try std.testing.expectEqual(@as(u64, 1), r.active_connections.load(.monotonic));
    // Underflow-safe.
    r.connectionClosed();
    r.connectionClosed();
    try std.testing.expectEqual(@as(u64, 0), r.active_connections.load(.monotonic));
}

test "prometheus render" {
    var r = Registry{};
    r.recordRequest();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "http_requests_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# TYPE http_requests_total counter") != null);
}
