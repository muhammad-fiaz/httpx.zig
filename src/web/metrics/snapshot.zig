//! Immutable point-in-time metrics and telemetry snapshots.

const std = @import("std");

pub const LATENCY_BUCKET_COUNT = 11;

/// Immutable point-in-time snapshot of the metrics registry.
pub const MetricsSnapshot = struct {
    requests_total: u64 = 0,
    responses_total: u64 = 0,
    errors_total: u64 = 0,
    timeouts_total: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    active_connections: u64 = 0,
    active_requests: u64 = 0,

    // Status classes
    status_2xx: u64 = 0,
    status_3xx: u64 = 0,
    status_4xx: u64 = 0,
    status_5xx: u64 = 0,

    // Methods
    method_get: u64 = 0,
    method_post: u64 = 0,
    method_put: u64 = 0,
    method_delete: u64 = 0,
    method_patch: u64 = 0,
    method_head: u64 = 0,
    method_options: u64 = 0,
    method_other: u64 = 0,

    // Duration Histogram
    duration_count: u64 = 0,
    duration_sum_seconds: f64 = 0.0,
    duration_buckets: [LATENCY_BUCKET_COUNT]u64 = [_]u64{0} ** LATENCY_BUCKET_COUNT,

    /// Returns the fraction of requests that resulted in an error (0.0 to 1.0).
    pub fn errorRate(self: MetricsSnapshot) f64 {
        if (self.requests_total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.errors_total)) / @as(f64, @floatFromInt(self.requests_total));
    }

    /// Returns the average request latency in seconds.
    pub fn averageLatencySeconds(self: MetricsSnapshot) f64 {
        if (self.duration_count == 0) return 0.0;
        return self.duration_sum_seconds / @as(f64, @floatFromInt(self.duration_count));
    }

    /// Returns the average request latency in milliseconds.
    pub fn averageLatencyMs(self: MetricsSnapshot) f64 {
        return self.averageLatencySeconds() * 1000.0;
    }
};

/// Point-in-time runtime snapshot of the HTTP server.
pub const ServerSnapshot = struct {
    uptime_ms: u64 = 0,
    active_connections: u64 = 0,
    active_requests: u64 = 0,
    requests_total: u64 = 0,
    responses_total: u64 = 0,
    errors_total: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    error_rate: f64 = 0.0,
    requests_per_second: f64 = 0.0,
    metrics: MetricsSnapshot = .{},

    /// Returns the pre-calculated error rate (errors_total / requests_total).
    pub fn errorRate(self: ServerSnapshot) f64 {
        return self.error_rate;
    }

    /// Returns the average requests per second since server start.
    pub fn requestsPerSecond(self: ServerSnapshot) f64 {
        return self.requests_per_second;
    }
};

/// Point-in-time runtime snapshot of the HTTP client.
pub const ClientSnapshot = struct {
    requests_total: u64 = 0,
    responses_total: u64 = 0,
    errors_total: u64 = 0,
    timeouts_total: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    active_connections: u64 = 0,
    pool_parked: usize = 0,
    pool_dropped_limit: u64 = 0,
    pool_dropped_stale: u64 = 0,
    dns_hits: u64 = 0,
    dns_misses: u64 = 0,
};

test "metrics snapshot calculations" {
    var snap = MetricsSnapshot{
        .requests_total = 100,
        .errors_total = 5,
        .duration_count = 10,
        .duration_sum_seconds = 0.5,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), snap.errorRate(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), snap.averageLatencySeconds(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), snap.averageLatencyMs(), 0.01);
}
