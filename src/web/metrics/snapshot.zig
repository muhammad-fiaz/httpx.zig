//! Immutable point-in-time metrics and telemetry snapshots.

const std = @import("std");

pub const LATENCY_BUCKET_COUNT = 11;

/// Immutable point-in-time snapshot of the metrics registry.
pub const MetricsSnapshot = struct {
    requestsTotal: u64 = 0,
    responsesTotal: u64 = 0,
    errorsTotal: u64 = 0,
    timeoutsTotal: u64 = 0,
    bytesIn: u64 = 0,
    bytesOut: u64 = 0,
    activeConnections: u64 = 0,
    activeRequests: u64 = 0,

    // Status classes
    status2xx: u64 = 0,
    status3xx: u64 = 0,
    status4xx: u64 = 0,
    status5xx: u64 = 0,

    // Methods
    methodGet: u64 = 0,
    methodPost: u64 = 0,
    methodPut: u64 = 0,
    methodDelete: u64 = 0,
    methodPatch: u64 = 0,
    methodHead: u64 = 0,
    methodOptions: u64 = 0,
    methodOther: u64 = 0,

    // Duration Histogram
    durationCount: u64 = 0,
    durationSumSeconds: f64 = 0.0,
    durationBuckets: [LATENCY_BUCKET_COUNT]u64 = [_]u64{0} ** LATENCY_BUCKET_COUNT,

    /// Returns the fraction of requests that resulted in an error (0.0 to 1.0).
    pub fn errorRate(self: MetricsSnapshot) f64 {
        if (self.requestsTotal == 0) return 0.0;
        return @as(f64, @floatFromInt(self.errorsTotal)) / @as(f64, @floatFromInt(self.requestsTotal));
    }

    /// Returns the average request latency in seconds.
    pub fn averageLatencySeconds(self: MetricsSnapshot) f64 {
        if (self.durationCount == 0) return 0.0;
        return self.durationSumSeconds / @as(f64, @floatFromInt(self.durationCount));
    }

    /// Returns the average request latency in milliseconds.
    pub fn averageLatencyMs(self: MetricsSnapshot) f64 {
        return self.averageLatencySeconds() * 1000.0;
    }
};

/// Point-in-time runtime snapshot of the HTTP server.
pub const ServerSnapshot = struct {
    uptimeMs: u64 = 0,
    activeConnections: u64 = 0,
    activeRequests: u64 = 0,
    requestsTotal: u64 = 0,
    responsesTotal: u64 = 0,
    errorsTotal: u64 = 0,
    bytesIn: u64 = 0,
    bytesOut: u64 = 0,
    metrics: MetricsSnapshot = .{},

    /// Fraction of requests that resulted in an error (0.0 to 1.0).
    pub fn errorRate(self: ServerSnapshot) f64 {
        if (self.requestsTotal == 0) return 0.0;
        return @as(f64, @floatFromInt(self.errorsTotal)) / @as(f64, @floatFromInt(self.requestsTotal));
    }

    /// Average requests per second since server start (0.0 when uptime is 0).
    pub fn requestsPerSecond(self: ServerSnapshot) f64 {
        if (self.uptimeMs == 0) return 0.0;
        return @as(f64, @floatFromInt(self.requestsTotal)) / (@as(f64, @floatFromInt(self.uptimeMs)) / 1000.0);
    }
};

/// Point-in-time runtime snapshot of the HTTP client.
pub const ClientSnapshot = struct {
    requestsTotal: u64 = 0,
    responsesTotal: u64 = 0,
    errorsTotal: u64 = 0,
    timeoutsTotal: u64 = 0,
    bytesSent: u64 = 0,
    bytesReceived: u64 = 0,
    activeConnections: u64 = 0,
    poolParked: usize = 0,
    poolDroppedLimit: u64 = 0,
    poolDroppedStale: u64 = 0,
    dnsHits: u64 = 0,
    dnsMisses: u64 = 0,
};

test "metrics snapshot calculations" {
    var snap = MetricsSnapshot{
        .requestsTotal = 100,
        .errorsTotal = 5,
        .durationCount = 10,
        .durationSumSeconds = 0.5,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), snap.errorRate(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), snap.averageLatencySeconds(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), snap.averageLatencyMs(), 0.01);
}
