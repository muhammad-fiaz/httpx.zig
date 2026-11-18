//! Immutable point-in-time metrics and telemetry snapshots.

const std = @import("std");
const z = @import("zigantic");

pub const LATENCY_BUCKET_COUNT = 11;

/// Immutable point-in-time snapshot of the metrics registry.
const MetricsSnapshotSchema = z.objectOf(.{
    .requestsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .responsesTotal = z.withDefault(z.integer(u64, .{}), 0),
    .errorsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .timeoutsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .bytesIn = z.withDefault(z.integer(u64, .{}), 0),
    .bytesOut = z.withDefault(z.integer(u64, .{}), 0),
    .activeConnections = z.withDefault(z.integer(u64, .{}), 0),
    .activeRequests = z.withDefault(z.integer(u64, .{}), 0),
    // Status classes
    .status2xx = z.withDefault(z.integer(u64, .{}), 0),
    .status3xx = z.withDefault(z.integer(u64, .{}), 0),
    .status4xx = z.withDefault(z.integer(u64, .{}), 0),
    .status5xx = z.withDefault(z.integer(u64, .{}), 0),
    // Methods
    .methodGet = z.withDefault(z.integer(u64, .{}), 0),
    .methodPost = z.withDefault(z.integer(u64, .{}), 0),
    .methodPut = z.withDefault(z.integer(u64, .{}), 0),
    .methodDelete = z.withDefault(z.integer(u64, .{}), 0),
    .methodPatch = z.withDefault(z.integer(u64, .{}), 0),
    .methodHead = z.withDefault(z.integer(u64, .{}), 0),
    .methodOptions = z.withDefault(z.integer(u64, .{}), 0),
    .methodOther = z.withDefault(z.integer(u64, .{}), 0),
    // Duration histogram
    .durationCount = z.withDefault(z.integer(u64, .{}), 0),
    .durationSumSeconds = z.withDefault(z.float(f64, .{}), 0.0),
    .durationBuckets = z.withDefault(z.fixedArray(z.integer(u64, .{}), LATENCY_BUCKET_COUNT, .{}), @splat(0)),
}, .{});
pub const MetricsSnapshot = MetricsSnapshotSchema.Value;

/// Fraction of requests that resulted in an error (0.0 to 1.0).
pub fn errorRate(snapshot: MetricsSnapshot) f64 {
    if (snapshot.requestsTotal == 0) return 0.0;
    return @as(f64, @floatFromInt(snapshot.errorsTotal)) / @as(f64, @floatFromInt(snapshot.requestsTotal));
}

/// Average request latency in seconds.
pub fn averageLatencySeconds(snapshot: MetricsSnapshot) f64 {
    if (snapshot.durationCount == 0) return 0.0;
    return snapshot.durationSumSeconds / @as(f64, @floatFromInt(snapshot.durationCount));
}

/// Average request latency in milliseconds.
pub fn averageLatencyMs(snapshot: MetricsSnapshot) f64 {
    return averageLatencySeconds(snapshot) * 1000.0;
}

/// Point-in-time runtime snapshot of the HTTP server.
const ServerSnapshotSchema = z.objectOf(.{
    .uptimeMs = z.withDefault(z.integer(u64, .{}), 0),
    .activeConnections = z.withDefault(z.integer(u64, .{}), 0),
    .activeRequests = z.withDefault(z.integer(u64, .{}), 0),
    .requestsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .responsesTotal = z.withDefault(z.integer(u64, .{}), 0),
    .errorsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .bytesIn = z.withDefault(z.integer(u64, .{}), 0),
    .bytesOut = z.withDefault(z.integer(u64, .{}), 0),
    .metrics = z.withDefault(MetricsSnapshotSchema, .{}),
}, .{});
pub const ServerSnapshot = ServerSnapshotSchema.Value;

/// Fraction of requests that resulted in an error (0.0 to 1.0).
pub fn serverErrorRate(snapshot: ServerSnapshot) f64 {
    if (snapshot.requestsTotal == 0) return 0.0;
    return @as(f64, @floatFromInt(snapshot.errorsTotal)) / @as(f64, @floatFromInt(snapshot.requestsTotal));
}

/// Average requests per second since server start (0.0 when uptime is 0).
pub fn requestsPerSecond(snapshot: ServerSnapshot) f64 {
    if (snapshot.uptimeMs == 0) return 0.0;
    return @as(f64, @floatFromInt(snapshot.requestsTotal)) / (@as(f64, @floatFromInt(snapshot.uptimeMs)) / 1000.0);
}

/// Point-in-time runtime snapshot of the HTTP client.
const ClientSnapshotSchema = z.objectOf(.{
    .requestsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .responsesTotal = z.withDefault(z.integer(u64, .{}), 0),
    .errorsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .timeoutsTotal = z.withDefault(z.integer(u64, .{}), 0),
    .bytesSent = z.withDefault(z.integer(u64, .{}), 0),
    .bytesReceived = z.withDefault(z.integer(u64, .{}), 0),
    .activeConnections = z.withDefault(z.integer(u64, .{}), 0),
    .poolParked = z.withDefault(z.integer(usize, .{}), 0),
    .poolDroppedLimit = z.withDefault(z.integer(u64, .{}), 0),
    .poolDroppedStale = z.withDefault(z.integer(u64, .{}), 0),
    .dnsHits = z.withDefault(z.integer(u64, .{}), 0),
    .dnsMisses = z.withDefault(z.integer(u64, .{}), 0),
}, .{});
pub const ClientSnapshot = ClientSnapshotSchema.Value;

test "metrics snapshot calculations" {
    const snap = MetricsSnapshot{
        .requestsTotal = 100,
        .errorsTotal = 5,
        .durationCount = 10,
        .durationSumSeconds = 0.5,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), errorRate(snap), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), averageLatencySeconds(snap), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), averageLatencyMs(snap), 0.01);
}
