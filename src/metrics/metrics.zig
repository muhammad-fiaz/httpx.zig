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

    // Connection metrics
    total_connections: Atomic(u64) = .init(0),
    new_connections: Atomic(u64) = .init(0),
    reused_connections: Atomic(u64) = .init(0),
    failed_connections: Atomic(u64) = .init(0),
    connection_timeouts: Atomic(u64) = .init(0),
    connection_resets: Atomic(u64) = .init(0),

    // DNS metrics
    dns_lookups: Atomic(u64) = .init(0),
    dns_successes: Atomic(u64) = .init(0),
    dns_failures: Atomic(u64) = .init(0),
    dns_cache_hits: Atomic(u64) = .init(0),
    dns_cache_misses: Atomic(u64) = .init(0),
    dns_total_ns: Atomic(u64) = .init(0),

    // TLS metrics
    tls_handshakes: Atomic(u64) = .init(0),
    tls_handshake_successes: Atomic(u64) = .init(0),
    tls_handshake_failures: Atomic(u64) = .init(0),
    tls_handshake_total_ns: Atomic(u64) = .init(0),

    // Retry metrics
    total_retries: Atomic(u64) = .init(0),
    retry_successes: Atomic(u64) = .init(0),
    retry_failures: Atomic(u64) = .init(0),

    // Redirect metrics
    redirects: Atomic(u64) = .init(0),
    redirect_failures: Atomic(u64) = .init(0),

    // HTTP/2 metrics
    http2_connections: Atomic(u64) = .init(0),
    http2_streams_opened: Atomic(u64) = .init(0),
    http2_streams_completed: Atomic(u64) = .init(0),
    http2_streams_reset: Atomic(u64) = .init(0),
    http2_goaway: Atomic(u64) = .init(0),

    // HTTP/3 / QUIC metrics
    http3_connections: Atomic(u64) = .init(0),
    http3_streams_opened: Atomic(u64) = .init(0),
    http3_streams_completed: Atomic(u64) = .init(0),
    http3_streams_reset: Atomic(u64) = .init(0),

    // Streaming metrics
    active_streams: Atomic(i64) = .init(0),
    completed_streams: Atomic(u64) = .init(0),
    bytes_streamed: Atomic(u64) = .init(0),

    // Cache metrics (application-level)
    cache_hits: Atomic(u64) = .init(0),
    cache_misses: Atomic(u64) = .init(0),
    cache_stores: Atomic(u64) = .init(0),
    cache_evictions: Atomic(u64) = .init(0),
    cache_revalidations: Atomic(u64) = .init(0),

    // Compression metrics
    compression_operations: Atomic(u64) = .init(0),
    decompression_operations: Atomic(u64) = .init(0),
    compressed_bytes: Atomic(u64) = .init(0),
    uncompressed_bytes: Atomic(u64) = .init(0),

    // Rate limiting metrics
    rate_limit_checked: Atomic(u64) = .init(0),
    rate_limit_allowed: Atomic(u64) = .init(0),
    rate_limit_rejected: Atomic(u64) = .init(0),

    // Security metrics
    csrf_rejections: Atomic(u64) = .init(0),
    ssrf_rejections: Atomic(u64) = .init(0),
    cors_rejections: Atomic(u64) = .init(0),
    auth_failures: Atomic(u64) = .init(0),

    // Server metrics
    active_requests: Atomic(i64) = .init(0),
    completed_requests: Atomic(u64) = .init(0),
    server_errors: Atomic(u64) = .init(0),

    // Request byte breakdown
    request_header_bytes: Atomic(u64) = .init(0),
    request_body_bytes: Atomic(u64) = .init(0),
    response_header_bytes: Atomic(u64) = .init(0),
    response_body_bytes: Atomic(u64) = .init(0),

    // WebSocket metrics
    ws_connections: Atomic(u64) = .init(0),
    ws_handshake_successes: Atomic(u64) = .init(0),
    ws_handshake_failures: Atomic(u64) = .init(0),
    ws_active_connections: Atomic(i64) = .init(0),
    ws_closed_connections: Atomic(u64) = .init(0),
    ws_messages_sent: Atomic(u64) = .init(0),
    ws_messages_received: Atomic(u64) = .init(0),
    ws_text_messages: Atomic(u64) = .init(0),
    ws_binary_messages: Atomic(u64) = .init(0),
    ws_ping_frames: Atomic(u64) = .init(0),
    ws_pong_frames: Atomic(u64) = .init(0),
    ws_close_frames: Atomic(u64) = .init(0),
    ws_bytes_sent: Atomic(u64) = .init(0),
    ws_bytes_received: Atomic(u64) = .init(0),
    ws_protocol_errors: Atomic(u64) = .init(0),
    ws_oversized_frames: Atomic(u64) = .init(0),

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

    /// Records a new TCP/TLS connection being established.
    pub fn connectionNew(self: *Self) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
        _ = self.new_connections.fetchAdd(1, .monotonic);
    }

    /// Records a pooled connection being reused.
    pub fn connectionReused(self: *Self) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
        _ = self.reused_connections.fetchAdd(1, .monotonic);
    }

    /// Records a connection failure.
    pub fn connectionFailed(self: *Self) void {
        _ = self.failed_connections.fetchAdd(1, .monotonic);
    }

    /// Records a connection timeout.
    pub fn connectionTimedOut(self: *Self) void {
        _ = self.connection_timeouts.fetchAdd(1, .monotonic);
    }

    /// Records a connection reset.
    pub fn connectionReset(self: *Self) void {
        _ = self.connection_resets.fetchAdd(1, .monotonic);
    }

    /// Records a DNS lookup.
    pub fn dnsLookup(self: *Self, success: bool, cached: bool, duration_ns: u64) void {
        _ = self.dns_lookups.fetchAdd(1, .monotonic);
        if (success) _ = self.dns_successes.fetchAdd(1, .monotonic) else _ = self.dns_failures.fetchAdd(1, .monotonic);
        if (cached) _ = self.dns_cache_hits.fetchAdd(1, .monotonic) else _ = self.dns_cache_misses.fetchAdd(1, .monotonic);
        _ = self.dns_total_ns.fetchAdd(duration_ns, .monotonic);
    }

    /// Records a TLS handshake.
    pub fn tlsHandshake(self: *Self, success: bool, duration_ns: u64) void {
        _ = self.tls_handshakes.fetchAdd(1, .monotonic);
        if (success) _ = self.tls_handshake_successes.fetchAdd(1, .monotonic) else _ = self.tls_handshake_failures.fetchAdd(1, .monotonic);
        _ = self.tls_handshake_total_ns.fetchAdd(duration_ns, .monotonic);
    }

    /// Records a retry attempt.
    pub fn retryAttempt(self: *Self) void {
        _ = self.total_retries.fetchAdd(1, .monotonic);
    }

    /// Records a retry success.
    pub fn retrySuccess(self: *Self) void {
        _ = self.retry_successes.fetchAdd(1, .monotonic);
    }

    /// Records a retry failure.
    pub fn retryFailure(self: *Self) void {
        _ = self.retry_failures.fetchAdd(1, .monotonic);
    }

    /// Records a redirect.
    pub fn redirect(self: *Self) void {
        _ = self.redirects.fetchAdd(1, .monotonic);
    }

    /// Records a redirect failure.
    pub fn redirectFailed(self: *Self) void {
        _ = self.redirect_failures.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/2 connection.
    pub fn http2Connection(self: *Self) void {
        _ = self.http2_connections.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/2 stream opened.
    pub fn http2StreamOpened(self: *Self) void {
        _ = self.http2_streams_opened.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/2 stream completed.
    pub fn http2StreamCompleted(self: *Self) void {
        _ = self.http2_streams_completed.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/2 stream reset.
    pub fn http2StreamReset(self: *Self) void {
        _ = self.http2_streams_reset.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/2 GOAWAY frame.
    pub fn http2Goaway(self: *Self) void {
        _ = self.http2_goaway.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/3 / QUIC connection.
    pub fn http3Connection(self: *Self) void {
        _ = self.http3_connections.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/3 stream opened.
    pub fn http3StreamOpened(self: *Self) void {
        _ = self.http3_streams_opened.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/3 stream completed.
    pub fn http3StreamCompleted(self: *Self) void {
        _ = self.http3_streams_completed.fetchAdd(1, .monotonic);
    }

    /// Records an HTTP/3 stream reset.
    pub fn http3StreamReset(self: *Self) void {
        _ = self.http3_streams_reset.fetchAdd(1, .monotonic);
    }

    /// Records a streaming operation started.
    pub fn streamStarted(self: *Self) void {
        _ = self.active_streams.fetchAdd(1, .monotonic);
    }

    /// Records a streaming operation completed.
    pub fn streamCompleted(self: *Self, bytes: u64) void {
        _ = self.active_streams.fetchSub(1, .monotonic);
        _ = self.completed_streams.fetchAdd(1, .monotonic);
        _ = self.bytes_streamed.fetchAdd(bytes, .monotonic);
    }

    /// Records a cache hit.
    pub fn cacheHit(self: *Self) void {
        _ = self.cache_hits.fetchAdd(1, .monotonic);
    }

    /// Records a cache miss.
    pub fn cacheMiss(self: *Self) void {
        _ = self.cache_misses.fetchAdd(1, .monotonic);
    }

    /// Records a cache store.
    pub fn cacheStore(self: *Self) void {
        _ = self.cache_stores.fetchAdd(1, .monotonic);
    }

    /// Records a cache eviction.
    pub fn cacheEviction(self: *Self) void {
        _ = self.cache_evictions.fetchAdd(1, .monotonic);
    }

    /// Records a cache revalidation.
    pub fn cacheRevalidation(self: *Self) void {
        _ = self.cache_revalidations.fetchAdd(1, .monotonic);
    }

    /// Records a compression operation.
    pub fn compression(self: *Self, uncompressed_size: u64, compressed_size: u64) void {
        _ = self.compression_operations.fetchAdd(1, .monotonic);
        _ = self.uncompressed_bytes.fetchAdd(uncompressed_size, .monotonic);
        _ = self.compressed_bytes.fetchAdd(compressed_size, .monotonic);
    }

    /// Records a decompression operation.
    pub fn decompression(self: *Self, compressed_size: u64, uncompressed_size: u64) void {
        _ = self.decompression_operations.fetchAdd(1, .monotonic);
        _ = self.compressed_bytes.fetchAdd(compressed_size, .monotonic);
        _ = self.uncompressed_bytes.fetchAdd(uncompressed_size, .monotonic);
    }

    /// Records a rate limit check.
    pub fn rateLimitCheck(self: *Self, allowed: bool) void {
        _ = self.rate_limit_checked.fetchAdd(1, .monotonic);
        if (allowed) _ = self.rate_limit_allowed.fetchAdd(1, .monotonic) else _ = self.rate_limit_rejected.fetchAdd(1, .monotonic);
    }

    /// Records a CSRF rejection.
    pub fn csrfRejection(self: *Self) void {
        _ = self.csrf_rejections.fetchAdd(1, .monotonic);
    }

    /// Records an SSRF rejection.
    pub fn ssrfRejection(self: *Self) void {
        _ = self.ssrf_rejections.fetchAdd(1, .monotonic);
    }

    /// Records a CORS rejection.
    pub fn corsRejection(self: *Self) void {
        _ = self.cors_rejections.fetchAdd(1, .monotonic);
    }

    /// Records an authentication failure.
    pub fn authFailure(self: *Self) void {
        _ = self.auth_failures.fetchAdd(1, .monotonic);
    }

    /// Records a server request started.
    pub fn serverRequestStarted(self: *Self) void {
        _ = self.active_requests.fetchAdd(1, .monotonic);
    }

    /// Records a server request completed.
    pub fn serverRequestCompleted(self: *Self, is_error: bool) void {
        _ = self.active_requests.fetchSub(1, .monotonic);
        _ = self.completed_requests.fetchAdd(1, .monotonic);
        if (is_error) _ = self.server_errors.fetchAdd(1, .monotonic);
    }

    /// Records request header bytes.
    pub fn recordRequestHeaders(self: *Self, bytes: u64) void {
        _ = self.request_header_bytes.fetchAdd(bytes, .monotonic);
    }

    /// Records request body bytes.
    pub fn recordRequestBody(self: *Self, bytes: u64) void {
        _ = self.request_body_bytes.fetchAdd(bytes, .monotonic);
    }

    /// Records response header bytes.
    pub fn recordResponseHeaders(self: *Self, bytes: u64) void {
        _ = self.response_header_bytes.fetchAdd(bytes, .monotonic);
    }

    /// Records response body bytes.
    pub fn recordResponseBody(self: *Self, bytes: u64) void {
        _ = self.response_body_bytes.fetchAdd(bytes, .monotonic);
    }

    // WebSocket metrics recording

    /// Records a WebSocket connection being opened.
    pub fn wsConnectionOpened(self: *Self) void {
        _ = self.ws_connections.fetchAdd(1, .monotonic);
        _ = self.ws_active_connections.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket connection being closed.
    pub fn wsConnectionClosed(self: *Self) void {
        _ = self.ws_active_connections.fetchSub(1, .monotonic);
        _ = self.ws_closed_connections.fetchAdd(1, .monotonic);
    }

    /// Records a successful WebSocket handshake.
    pub fn wsHandshakeSuccess(self: *Self) void {
        _ = self.ws_handshake_successes.fetchAdd(1, .monotonic);
    }

    /// Records a failed WebSocket handshake.
    pub fn wsHandshakeFailure(self: *Self) void {
        _ = self.ws_handshake_failures.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket message sent.
    pub fn wsMessageSent(self: *Self, opcode: u4, bytes: u64) void {
        _ = self.ws_messages_sent.fetchAdd(1, .monotonic);
        _ = self.ws_bytes_sent.fetchAdd(bytes, .monotonic);
        if (opcode == 0x1) _ = self.ws_text_messages.fetchAdd(1, .monotonic);
        if (opcode == 0x2) _ = self.ws_binary_messages.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket message received.
    pub fn wsMessageReceived(self: *Self, opcode: u4, bytes: u64) void {
        _ = self.ws_messages_received.fetchAdd(1, .monotonic);
        _ = self.ws_bytes_received.fetchAdd(bytes, .monotonic);
        if (opcode == 0x1) _ = self.ws_text_messages.fetchAdd(1, .monotonic);
        if (opcode == 0x2) _ = self.ws_binary_messages.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket ping frame sent/received.
    pub fn wsPing(self: *Self) void {
        _ = self.ws_ping_frames.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket pong frame sent/received.
    pub fn wsPong(self: *Self) void {
        _ = self.ws_pong_frames.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket close frame sent/received.
    pub fn wsClose(self: *Self) void {
        _ = self.ws_close_frames.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket protocol error.
    pub fn wsProtocolError(self: *Self) void {
        _ = self.ws_protocol_errors.fetchAdd(1, .monotonic);
    }

    /// Records a WebSocket oversized frame rejection.
    pub fn wsOversizedFrame(self: *Self) void {
        _ = self.ws_oversized_frames.fetchAdd(1, .monotonic);
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
        self.total_connections.store(0, .monotonic);
        self.new_connections.store(0, .monotonic);
        self.reused_connections.store(0, .monotonic);
        self.failed_connections.store(0, .monotonic);
        self.connection_timeouts.store(0, .monotonic);
        self.connection_resets.store(0, .monotonic);
        self.dns_lookups.store(0, .monotonic);
        self.dns_successes.store(0, .monotonic);
        self.dns_failures.store(0, .monotonic);
        self.dns_cache_hits.store(0, .monotonic);
        self.dns_cache_misses.store(0, .monotonic);
        self.dns_total_ns.store(0, .monotonic);
        self.tls_handshakes.store(0, .monotonic);
        self.tls_handshake_successes.store(0, .monotonic);
        self.tls_handshake_failures.store(0, .monotonic);
        self.tls_handshake_total_ns.store(0, .monotonic);
        self.total_retries.store(0, .monotonic);
        self.retry_successes.store(0, .monotonic);
        self.retry_failures.store(0, .monotonic);
        self.redirects.store(0, .monotonic);
        self.redirect_failures.store(0, .monotonic);
        self.http2_connections.store(0, .monotonic);
        self.http2_streams_opened.store(0, .monotonic);
        self.http2_streams_completed.store(0, .monotonic);
        self.http2_streams_reset.store(0, .monotonic);
        self.http2_goaway.store(0, .monotonic);
        self.http3_connections.store(0, .monotonic);
        self.http3_streams_opened.store(0, .monotonic);
        self.http3_streams_completed.store(0, .monotonic);
        self.http3_streams_reset.store(0, .monotonic);
        self.active_streams.store(0, .monotonic);
        self.completed_streams.store(0, .monotonic);
        self.bytes_streamed.store(0, .monotonic);
        self.cache_hits.store(0, .monotonic);
        self.cache_misses.store(0, .monotonic);
        self.cache_stores.store(0, .monotonic);
        self.cache_evictions.store(0, .monotonic);
        self.cache_revalidations.store(0, .monotonic);
        self.compression_operations.store(0, .monotonic);
        self.decompression_operations.store(0, .monotonic);
        self.compressed_bytes.store(0, .monotonic);
        self.uncompressed_bytes.store(0, .monotonic);
        self.rate_limit_checked.store(0, .monotonic);
        self.rate_limit_allowed.store(0, .monotonic);
        self.rate_limit_rejected.store(0, .monotonic);
        self.csrf_rejections.store(0, .monotonic);
        self.ssrf_rejections.store(0, .monotonic);
        self.cors_rejections.store(0, .monotonic);
        self.auth_failures.store(0, .monotonic);
        self.active_requests.store(0, .monotonic);
        self.completed_requests.store(0, .monotonic);
        self.server_errors.store(0, .monotonic);
        self.request_header_bytes.store(0, .monotonic);
        self.request_body_bytes.store(0, .monotonic);
        self.response_header_bytes.store(0, .monotonic);
        self.response_body_bytes.store(0, .monotonic);
        self.ws_connections.store(0, .monotonic);
        self.ws_handshake_successes.store(0, .monotonic);
        self.ws_handshake_failures.store(0, .monotonic);
        self.ws_active_connections.store(0, .monotonic);
        self.ws_closed_connections.store(0, .monotonic);
        self.ws_messages_sent.store(0, .monotonic);
        self.ws_messages_received.store(0, .monotonic);
        self.ws_text_messages.store(0, .monotonic);
        self.ws_binary_messages.store(0, .monotonic);
        self.ws_ping_frames.store(0, .monotonic);
        self.ws_pong_frames.store(0, .monotonic);
        self.ws_close_frames.store(0, .monotonic);
        self.ws_bytes_sent.store(0, .monotonic);
        self.ws_bytes_received.store(0, .monotonic);
        self.ws_protocol_errors.store(0, .monotonic);
        self.ws_oversized_frames.store(0, .monotonic);
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
            .total_connections = self.total_connections.load(.monotonic),
            .new_connections = self.new_connections.load(.monotonic),
            .reused_connections = self.reused_connections.load(.monotonic),
            .failed_connections = self.failed_connections.load(.monotonic),
            .connection_timeouts = self.connection_timeouts.load(.monotonic),
            .connection_resets = self.connection_resets.load(.monotonic),
            .dns_lookups = self.dns_lookups.load(.monotonic),
            .dns_successes = self.dns_successes.load(.monotonic),
            .dns_failures = self.dns_failures.load(.monotonic),
            .dns_cache_hits = self.dns_cache_hits.load(.monotonic),
            .dns_cache_misses = self.dns_cache_misses.load(.monotonic),
            .dns_total_ns = self.dns_total_ns.load(.monotonic),
            .tls_handshakes = self.tls_handshakes.load(.monotonic),
            .tls_handshake_successes = self.tls_handshake_successes.load(.monotonic),
            .tls_handshake_failures = self.tls_handshake_failures.load(.monotonic),
            .tls_handshake_total_ns = self.tls_handshake_total_ns.load(.monotonic),
            .total_retries = self.total_retries.load(.monotonic),
            .retry_successes = self.retry_successes.load(.monotonic),
            .retry_failures = self.retry_failures.load(.monotonic),
            .redirects = self.redirects.load(.monotonic),
            .redirect_failures = self.redirect_failures.load(.monotonic),
            .http2_connections = self.http2_connections.load(.monotonic),
            .http2_streams_opened = self.http2_streams_opened.load(.monotonic),
            .http2_streams_completed = self.http2_streams_completed.load(.monotonic),
            .http2_streams_reset = self.http2_streams_reset.load(.monotonic),
            .http2_goaway = self.http2_goaway.load(.monotonic),
            .http3_connections = self.http3_connections.load(.monotonic),
            .http3_streams_opened = self.http3_streams_opened.load(.monotonic),
            .http3_streams_completed = self.http3_streams_completed.load(.monotonic),
            .http3_streams_reset = self.http3_streams_reset.load(.monotonic),
            .active_streams = self.active_streams.load(.monotonic),
            .completed_streams = self.completed_streams.load(.monotonic),
            .bytes_streamed = self.bytes_streamed.load(.monotonic),
            .cache_hits = self.cache_hits.load(.monotonic),
            .cache_misses = self.cache_misses.load(.monotonic),
            .cache_stores = self.cache_stores.load(.monotonic),
            .cache_evictions = self.cache_evictions.load(.monotonic),
            .cache_revalidations = self.cache_revalidations.load(.monotonic),
            .compression_operations = self.compression_operations.load(.monotonic),
            .decompression_operations = self.decompression_operations.load(.monotonic),
            .compressed_bytes = self.compressed_bytes.load(.monotonic),
            .uncompressed_bytes = self.uncompressed_bytes.load(.monotonic),
            .rate_limit_checked = self.rate_limit_checked.load(.monotonic),
            .rate_limit_allowed = self.rate_limit_allowed.load(.monotonic),
            .rate_limit_rejected = self.rate_limit_rejected.load(.monotonic),
            .csrf_rejections = self.csrf_rejections.load(.monotonic),
            .ssrf_rejections = self.ssrf_rejections.load(.monotonic),
            .cors_rejections = self.cors_rejections.load(.monotonic),
            .auth_failures = self.auth_failures.load(.monotonic),
            .active_requests = self.active_requests.load(.monotonic),
            .completed_requests = self.completed_requests.load(.monotonic),
            .server_errors = self.server_errors.load(.monotonic),
            .request_header_bytes = self.request_header_bytes.load(.monotonic),
            .request_body_bytes = self.request_body_bytes.load(.monotonic),
            .response_header_bytes = self.response_header_bytes.load(.monotonic),
            .response_body_bytes = self.response_body_bytes.load(.monotonic),
            .ws_connections = self.ws_connections.load(.monotonic),
            .ws_handshake_successes = self.ws_handshake_successes.load(.monotonic),
            .ws_handshake_failures = self.ws_handshake_failures.load(.monotonic),
            .ws_active_connections = self.ws_active_connections.load(.monotonic),
            .ws_closed_connections = self.ws_closed_connections.load(.monotonic),
            .ws_messages_sent = self.ws_messages_sent.load(.monotonic),
            .ws_messages_received = self.ws_messages_received.load(.monotonic),
            .ws_text_messages = self.ws_text_messages.load(.monotonic),
            .ws_binary_messages = self.ws_binary_messages.load(.monotonic),
            .ws_ping_frames = self.ws_ping_frames.load(.monotonic),
            .ws_pong_frames = self.ws_pong_frames.load(.monotonic),
            .ws_close_frames = self.ws_close_frames.load(.monotonic),
            .ws_bytes_sent = self.ws_bytes_sent.load(.monotonic),
            .ws_bytes_received = self.ws_bytes_received.load(.monotonic),
            .ws_protocol_errors = self.ws_protocol_errors.load(.monotonic),
            .ws_oversized_frames = self.ws_oversized_frames.load(.monotonic),
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

    // Connection metrics
    total_connections: u64,
    new_connections: u64,
    reused_connections: u64,
    failed_connections: u64,
    connection_timeouts: u64,
    connection_resets: u64,

    // DNS metrics
    dns_lookups: u64,
    dns_successes: u64,
    dns_failures: u64,
    dns_cache_hits: u64,
    dns_cache_misses: u64,
    dns_total_ns: u64,

    // TLS metrics
    tls_handshakes: u64,
    tls_handshake_successes: u64,
    tls_handshake_failures: u64,
    tls_handshake_total_ns: u64,

    // Retry metrics
    total_retries: u64,
    retry_successes: u64,
    retry_failures: u64,

    // Redirect metrics
    redirects: u64,
    redirect_failures: u64,

    // HTTP/2 metrics
    http2_connections: u64,
    http2_streams_opened: u64,
    http2_streams_completed: u64,
    http2_streams_reset: u64,
    http2_goaway: u64,

    // HTTP/3 / QUIC metrics
    http3_connections: u64,
    http3_streams_opened: u64,
    http3_streams_completed: u64,
    http3_streams_reset: u64,

    // Streaming metrics
    active_streams: i64,
    completed_streams: u64,
    bytes_streamed: u64,

    // Cache metrics
    cache_hits: u64,
    cache_misses: u64,
    cache_stores: u64,
    cache_evictions: u64,
    cache_revalidations: u64,

    // Compression metrics
    compression_operations: u64,
    decompression_operations: u64,
    compressed_bytes: u64,
    uncompressed_bytes: u64,

    // Rate limiting metrics
    rate_limit_checked: u64,
    rate_limit_allowed: u64,
    rate_limit_rejected: u64,

    // Security metrics
    csrf_rejections: u64,
    ssrf_rejections: u64,
    cors_rejections: u64,
    auth_failures: u64,

    // Server metrics
    active_requests: i64,
    completed_requests: u64,
    server_errors: u64,

    // Request/response byte breakdown
    request_header_bytes: u64,
    request_body_bytes: u64,
    response_header_bytes: u64,
    response_body_bytes: u64,

    // WebSocket metrics
    ws_connections: u64,
    ws_handshake_successes: u64,
    ws_handshake_failures: u64,
    ws_active_connections: i64,
    ws_closed_connections: u64,
    ws_messages_sent: u64,
    ws_messages_received: u64,
    ws_text_messages: u64,
    ws_binary_messages: u64,
    ws_ping_frames: u64,
    ws_pong_frames: u64,
    ws_close_frames: u64,
    ws_bytes_sent: u64,
    ws_bytes_received: u64,
    ws_protocol_errors: u64,
    ws_oversized_frames: u64,

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

    pub fn totalConnections(self: *const MetricsSnapshot) u64 {
        return self.total_connections;
    }

    pub fn newConnections(self: *const MetricsSnapshot) u64 {
        return self.new_connections;
    }

    pub fn reusedConnections(self: *const MetricsSnapshot) u64 {
        return self.reused_connections;
    }

    pub fn failedConnections(self: *const MetricsSnapshot) u64 {
        return self.failed_connections;
    }

    pub fn connectionTimeouts(self: *const MetricsSnapshot) u64 {
        return self.connection_timeouts;
    }

    pub fn connectionResets(self: *const MetricsSnapshot) u64 {
        return self.connection_resets;
    }

    pub fn dnsLookups(self: *const MetricsSnapshot) u64 {
        return self.dns_lookups;
    }

    pub fn dnsSuccesses(self: *const MetricsSnapshot) u64 {
        return self.dns_successes;
    }

    pub fn dnsFailures(self: *const MetricsSnapshot) u64 {
        return self.dns_failures;
    }

    pub fn dnsCacheHits(self: *const MetricsSnapshot) u64 {
        return self.dns_cache_hits;
    }

    pub fn dnsCacheMisses(self: *const MetricsSnapshot) u64 {
        return self.dns_cache_misses;
    }

    pub fn dnsTotalNs(self: *const MetricsSnapshot) u64 {
        return self.dns_total_ns;
    }

    pub fn tlsHandshakes(self: *const MetricsSnapshot) u64 {
        return self.tls_handshakes;
    }

    pub fn tlsHandshakeSuccesses(self: *const MetricsSnapshot) u64 {
        return self.tls_handshake_successes;
    }

    pub fn tlsHandshakeFailures(self: *const MetricsSnapshot) u64 {
        return self.tls_handshake_failures;
    }

    pub fn tlsHandshakeTotalNs(self: *const MetricsSnapshot) u64 {
        return self.tls_handshake_total_ns;
    }

    pub fn totalRetries(self: *const MetricsSnapshot) u64 {
        return self.total_retries;
    }

    pub fn retrySuccesses(self: *const MetricsSnapshot) u64 {
        return self.retry_successes;
    }

    pub fn retryFailures(self: *const MetricsSnapshot) u64 {
        return self.retry_failures;
    }

    pub fn totalRedirects(self: *const MetricsSnapshot) u64 {
        return self.redirects;
    }

    pub fn redirectFailures(self: *const MetricsSnapshot) u64 {
        return self.redirect_failures;
    }

    pub fn http2Connections(self: *const MetricsSnapshot) u64 {
        return self.http2_connections;
    }

    pub fn http2StreamsOpened(self: *const MetricsSnapshot) u64 {
        return self.http2_streams_opened;
    }

    pub fn http2StreamsCompleted(self: *const MetricsSnapshot) u64 {
        return self.http2_streams_completed;
    }

    pub fn http2StreamsReset(self: *const MetricsSnapshot) u64 {
        return self.http2_streams_reset;
    }

    pub fn http2Goaway(self: *const MetricsSnapshot) u64 {
        return self.http2_goaway;
    }

    pub fn http3Connections(self: *const MetricsSnapshot) u64 {
        return self.http3_connections;
    }

    pub fn http3StreamsOpened(self: *const MetricsSnapshot) u64 {
        return self.http3_streams_opened;
    }

    pub fn http3StreamsCompleted(self: *const MetricsSnapshot) u64 {
        return self.http3_streams_completed;
    }

    pub fn http3StreamsReset(self: *const MetricsSnapshot) u64 {
        return self.http3_streams_reset;
    }

    pub fn activeStreams(self: *const MetricsSnapshot) i64 {
        return self.active_streams;
    }

    pub fn completedStreams(self: *const MetricsSnapshot) u64 {
        return self.completed_streams;
    }

    pub fn bytesStreamed(self: *const MetricsSnapshot) u64 {
        return self.bytes_streamed;
    }

    pub fn cacheHits(self: *const MetricsSnapshot) u64 {
        return self.cache_hits;
    }

    pub fn cacheMisses(self: *const MetricsSnapshot) u64 {
        return self.cache_misses;
    }

    pub fn cacheStores(self: *const MetricsSnapshot) u64 {
        return self.cache_stores;
    }

    pub fn cacheEvictions(self: *const MetricsSnapshot) u64 {
        return self.cache_evictions;
    }

    pub fn cacheRevalidations(self: *const MetricsSnapshot) u64 {
        return self.cache_revalidations;
    }

    pub fn compressionOperations(self: *const MetricsSnapshot) u64 {
        return self.compression_operations;
    }

    pub fn decompressionOperations(self: *const MetricsSnapshot) u64 {
        return self.decompression_operations;
    }

    pub fn compressedBytes(self: *const MetricsSnapshot) u64 {
        return self.compressed_bytes;
    }

    pub fn uncompressedBytes(self: *const MetricsSnapshot) u64 {
        return self.uncompressed_bytes;
    }

    pub fn rateLimitChecked(self: *const MetricsSnapshot) u64 {
        return self.rate_limit_checked;
    }

    pub fn rateLimitAllowed(self: *const MetricsSnapshot) u64 {
        return self.rate_limit_allowed;
    }

    pub fn rateLimitRejected(self: *const MetricsSnapshot) u64 {
        return self.rate_limit_rejected;
    }

    pub fn csrfRejections(self: *const MetricsSnapshot) u64 {
        return self.csrf_rejections;
    }

    pub fn ssrfRejections(self: *const MetricsSnapshot) u64 {
        return self.ssrf_rejections;
    }

    pub fn corsRejections(self: *const MetricsSnapshot) u64 {
        return self.cors_rejections;
    }

    pub fn authFailures(self: *const MetricsSnapshot) u64 {
        return self.auth_failures;
    }

    pub fn activeRequests(self: *const MetricsSnapshot) i64 {
        return self.active_requests;
    }

    pub fn completedRequests(self: *const MetricsSnapshot) u64 {
        return self.completed_requests;
    }

    pub fn serverErrors(self: *const MetricsSnapshot) u64 {
        return self.server_errors;
    }

    pub fn requestHeaderBytes(self: *const MetricsSnapshot) u64 {
        return self.request_header_bytes;
    }

    pub fn requestBodyBytes(self: *const MetricsSnapshot) u64 {
        return self.request_body_bytes;
    }

    pub fn responseHeaderBytes(self: *const MetricsSnapshot) u64 {
        return self.response_header_bytes;
    }

    pub fn responseBodyBytes(self: *const MetricsSnapshot) u64 {
        return self.response_body_bytes;
    }

    // Computed rate getters

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

    pub fn connectionReuseRate(self: *const MetricsSnapshot) f64 {
        if (self.total_connections == 0) return 0.0;
        return @as(f64, @floatFromInt(self.reused_connections)) / @as(f64, @floatFromInt(self.total_connections));
    }

    pub fn connectionFailureRate(self: *const MetricsSnapshot) f64 {
        if (self.total_connections == 0) return 0.0;
        return @as(f64, @floatFromInt(self.failed_connections)) / @as(f64, @floatFromInt(self.total_connections));
    }

    pub fn avgDNSLatencyNs(self: *const MetricsSnapshot) u64 {
        if (self.dns_lookups == 0) return 0;
        return self.dns_total_ns / self.dns_lookups;
    }

    pub fn dnsSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.dns_lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.dns_successes)) / @as(f64, @floatFromInt(self.dns_lookups));
    }

    pub fn dnsCacheHitRate(self: *const MetricsSnapshot) f64 {
        if (self.dns_lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.dns_cache_hits)) / @as(f64, @floatFromInt(self.dns_lookups));
    }

    pub fn avgTLSHandshakeNs(self: *const MetricsSnapshot) u64 {
        if (self.tls_handshakes == 0) return 0;
        return self.tls_handshake_total_ns / self.tls_handshakes;
    }

    pub fn tlsHandshakeSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.tls_handshakes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.tls_handshake_successes)) / @as(f64, @floatFromInt(self.tls_handshakes));
    }

    pub fn retrySuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.total_retries == 0) return 0.0;
        return @as(f64, @floatFromInt(self.retry_successes)) / @as(f64, @floatFromInt(self.total_retries));
    }

    pub fn redirectSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.redirects == 0) return 0.0;
        return @as(f64, @floatFromInt(self.redirects - self.redirect_failures)) / @as(f64, @floatFromInt(self.redirects));
    }

    pub fn http2StreamSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.http2_streams_opened == 0) return 0.0;
        return @as(f64, @floatFromInt(self.http2_streams_completed)) / @as(f64, @floatFromInt(self.http2_streams_opened));
    }

    pub fn http3StreamSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.http3_streams_opened == 0) return 0.0;
        return @as(f64, @floatFromInt(self.http3_streams_completed)) / @as(f64, @floatFromInt(self.http3_streams_opened));
    }

    pub fn cacheHitRate(self: *const MetricsSnapshot) f64 {
        const total_cache = self.cache_hits + self.cache_misses;
        if (total_cache == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total_cache));
    }

    pub fn compressionRatio(self: *const MetricsSnapshot) f64 {
        if (self.uncompressed_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.compressed_bytes)) / @as(f64, @floatFromInt(self.uncompressed_bytes));
    }

    pub fn compressionSavingsBytes(self: *const MetricsSnapshot) u64 {
        if (self.uncompressed_bytes <= self.compressed_bytes) return 0;
        return self.uncompressed_bytes - self.compressed_bytes;
    }

    pub fn compressionSavingsPercent(self: *const MetricsSnapshot) f64 {
        if (self.uncompressed_bytes == 0) return 0.0;
        if (self.uncompressed_bytes <= self.compressed_bytes) return 0.0;
        return @as(f64, @floatFromInt(self.uncompressed_bytes - self.compressed_bytes)) / @as(f64, @floatFromInt(self.uncompressed_bytes));
    }

    pub fn rateLimitRejectionRate(self: *const MetricsSnapshot) f64 {
        if (self.rate_limit_checked == 0) return 0.0;
        return @as(f64, @floatFromInt(self.rate_limit_rejected)) / @as(f64, @floatFromInt(self.rate_limit_checked));
    }

    pub fn totalSecurityRejections(self: *const MetricsSnapshot) u64 {
        return self.csrf_rejections + self.ssrf_rejections + self.cors_rejections + self.auth_failures;
    }

    pub fn serverRequestSuccessRate(self: *const MetricsSnapshot) f64 {
        if (self.completed_requests == 0) return 0.0;
        return @as(f64, @floatFromInt(self.completed_requests - self.server_errors)) / @as(f64, @floatFromInt(self.completed_requests));
    }

    pub fn totalRequestBytes(self: *const MetricsSnapshot) u64 {
        return self.request_header_bytes + self.request_body_bytes;
    }

    pub fn totalResponseBytes(self: *const MetricsSnapshot) u64 {
        return self.response_header_bytes + self.response_body_bytes;
    }

    pub fn avgStreamBytesPerResponse(self: *const MetricsSnapshot) u64 {
        if (self.completed_streams == 0) return 0;
        return self.bytes_streamed / self.completed_streams;
    }

    // WebSocket getters

    pub fn wsConnections(self: *const MetricsSnapshot) u64 {
        return self.ws_connections;
    }

    pub fn wsHandshakeSuccesses(self: *const MetricsSnapshot) u64 {
        return self.ws_handshake_successes;
    }

    pub fn wsHandshakeFailures(self: *const MetricsSnapshot) u64 {
        return self.ws_handshake_failures;
    }

    pub fn wsActiveConnections(self: *const MetricsSnapshot) i64 {
        return self.ws_active_connections;
    }

    pub fn wsClosedConnections(self: *const MetricsSnapshot) u64 {
        return self.ws_closed_connections;
    }

    pub fn wsMessagesSent(self: *const MetricsSnapshot) u64 {
        return self.ws_messages_sent;
    }

    pub fn wsMessagesReceived(self: *const MetricsSnapshot) u64 {
        return self.ws_messages_received;
    }

    pub fn wsTextMessages(self: *const MetricsSnapshot) u64 {
        return self.ws_text_messages;
    }

    pub fn wsBinaryMessages(self: *const MetricsSnapshot) u64 {
        return self.ws_binary_messages;
    }

    pub fn wsPingFrames(self: *const MetricsSnapshot) u64 {
        return self.ws_ping_frames;
    }

    pub fn wsPongFrames(self: *const MetricsSnapshot) u64 {
        return self.ws_pong_frames;
    }

    pub fn wsCloseFrames(self: *const MetricsSnapshot) u64 {
        return self.ws_close_frames;
    }

    pub fn wsBytesSent(self: *const MetricsSnapshot) u64 {
        return self.ws_bytes_sent;
    }

    pub fn wsBytesReceived(self: *const MetricsSnapshot) u64 {
        return self.ws_bytes_received;
    }

    pub fn wsProtocolErrors(self: *const MetricsSnapshot) u64 {
        return self.ws_protocol_errors;
    }

    pub fn wsOversizedFrames(self: *const MetricsSnapshot) u64 {
        return self.ws_oversized_frames;
    }

    pub fn wsHandshakeSuccessRate(self: *const MetricsSnapshot) f64 {
        const total = self.ws_handshake_successes + self.ws_handshake_failures;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.ws_handshake_successes)) / @as(f64, @floatFromInt(total));
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

test "Metrics connection tracking" {
    var m = Metrics.init();
    m.connectionNew();
    m.connectionNew();
    m.connectionReused();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.total_connections);
    try std.testing.expectEqual(@as(u64, 2), snap.new_connections);
    try std.testing.expectEqual(@as(u64, 1), snap.reused_connections);

    const reuse_rate = snap.connectionReuseRate();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) / 3.0, reuse_rate, 0.01);
}

test "Metrics connection failure tracking" {
    var m = Metrics.init();
    m.connectionFailed();
    m.connectionTimedOut();
    m.connectionReset();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.failed_connections);
    try std.testing.expectEqual(@as(u64, 1), snap.connection_timeouts);
    try std.testing.expectEqual(@as(u64, 1), snap.connection_resets);
    try std.testing.expectEqual(@as(u64, 0), snap.errors());
}

test "Metrics DNS tracking" {
    var m = Metrics.init();
    m.dnsLookup(true, false, 1000);
    m.dnsLookup(true, true, 200);
    m.dnsLookup(false, false, 500);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.dns_lookups);
    try std.testing.expectEqual(@as(u64, 2), snap.dns_successes);
    try std.testing.expectEqual(@as(u64, 1), snap.dns_failures);
    try std.testing.expectEqual(@as(u64, 1), snap.dns_cache_hits);
    try std.testing.expectEqual(@as(u64, 2), snap.dns_cache_misses);
    try std.testing.expectEqual(@as(u64, 1700), snap.dns_total_ns);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0) / 3.0, snap.dnsSuccessRate(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) / 3.0, snap.dnsCacheHitRate(), 0.01);
    try std.testing.expectEqual(@as(u64, 566), snap.avgDNSLatencyNs());
}

test "Metrics TLS tracking" {
    var m = Metrics.init();
    m.tlsHandshake(true, 5000);
    m.tlsHandshake(true, 3000);
    m.tlsHandshake(false, 1000);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.tls_handshakes);
    try std.testing.expectEqual(@as(u64, 2), snap.tls_handshake_successes);
    try std.testing.expectEqual(@as(u64, 1), snap.tls_handshake_failures);
    try std.testing.expectEqual(@as(u64, 9000), snap.tls_handshake_total_ns);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0) / 3.0, snap.tlsHandshakeSuccessRate(), 0.01);
    try std.testing.expectEqual(@as(u64, 3000), snap.avgTLSHandshakeNs());
}

test "Metrics retry tracking" {
    var m = Metrics.init();
    m.retryAttempt();
    m.retryAttempt();
    m.retrySuccess();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.total_retries);
    try std.testing.expectEqual(@as(u64, 1), snap.retry_successes);
    try std.testing.expectEqual(@as(u64, 0), snap.retry_failures);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), snap.retrySuccessRate(), 0.01);
}

test "Metrics redirect tracking" {
    var m = Metrics.init();
    m.redirect();
    m.redirect();
    m.redirectFailed();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.redirects);
    try std.testing.expectEqual(@as(u64, 1), snap.redirect_failures);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), snap.redirectSuccessRate(), 0.01);
}

test "Metrics HTTP/2 tracking" {
    var m = Metrics.init();
    m.http2Connection();
    m.http2StreamOpened();
    m.http2StreamOpened();
    m.http2StreamCompleted();
    m.http2StreamReset();
    m.http2Goaway();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.http2_connections);
    try std.testing.expectEqual(@as(u64, 2), snap.http2_streams_opened);
    try std.testing.expectEqual(@as(u64, 1), snap.http2_streams_completed);
    try std.testing.expectEqual(@as(u64, 1), snap.http2_streams_reset);
    try std.testing.expectEqual(@as(u64, 1), snap.http2_goaway);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), snap.http2StreamSuccessRate(), 0.01);
}

test "Metrics HTTP/3 tracking" {
    var m = Metrics.init();
    m.http3Connection();
    m.http3StreamOpened();
    m.http3StreamCompleted();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.http3_connections);
    try std.testing.expectEqual(@as(u64, 1), snap.http3_streams_opened);
    try std.testing.expectEqual(@as(u64, 1), snap.http3_streams_completed);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), snap.http3StreamSuccessRate(), 0.01);
}

test "Metrics streaming tracking" {
    var m = Metrics.init();
    m.streamStarted();
    m.streamStarted();
    m.streamCompleted(1024);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(i64, 1), snap.active_streams);
    try std.testing.expectEqual(@as(u64, 1), snap.completed_streams);
    try std.testing.expectEqual(@as(u64, 1024), snap.bytes_streamed);
    try std.testing.expectEqual(@as(u64, 1024), snap.avgStreamBytesPerResponse());
}

test "Metrics cache tracking" {
    var m = Metrics.init();
    m.cacheHit();
    m.cacheHit();
    m.cacheMiss();
    m.cacheStore();
    m.cacheEviction();
    m.cacheRevalidation();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.cache_hits);
    try std.testing.expectEqual(@as(u64, 1), snap.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), snap.cache_stores);
    try std.testing.expectEqual(@as(u64, 1), snap.cache_evictions);
    try std.testing.expectEqual(@as(u64, 1), snap.cache_revalidations);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0) / 3.0, snap.cacheHitRate(), 0.01);
}

test "Metrics compression tracking" {
    var m = Metrics.init();
    m.compression(1000, 400);
    m.compression(2000, 800);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.compression_operations);
    try std.testing.expectEqual(@as(u64, 1200), snap.compressed_bytes);
    try std.testing.expectEqual(@as(u64, 3000), snap.uncompressed_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), snap.compressionRatio(), 0.01);
    try std.testing.expectEqual(@as(u64, 1800), snap.compressionSavingsBytes());
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), snap.compressionSavingsPercent(), 0.01);
}

test "Metrics rate limiting tracking" {
    var m = Metrics.init();
    m.rateLimitCheck(true);
    m.rateLimitCheck(true);
    m.rateLimitCheck(false);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.rate_limit_checked);
    try std.testing.expectEqual(@as(u64, 2), snap.rate_limit_allowed);
    try std.testing.expectEqual(@as(u64, 1), snap.rate_limit_rejected);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) / 3.0, snap.rateLimitRejectionRate(), 0.01);
}

test "Metrics security tracking" {
    var m = Metrics.init();
    m.csrfRejection();
    m.ssrfRejection();
    m.ssrfRejection();
    m.corsRejection();
    m.authFailure();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.csrf_rejections);
    try std.testing.expectEqual(@as(u64, 2), snap.ssrf_rejections);
    try std.testing.expectEqual(@as(u64, 1), snap.cors_rejections);
    try std.testing.expectEqual(@as(u64, 1), snap.auth_failures);
    try std.testing.expectEqual(@as(u64, 5), snap.totalSecurityRejections());
}

test "Metrics server tracking" {
    var m = Metrics.init();
    m.serverRequestStarted();
    m.serverRequestStarted();
    m.serverRequestCompleted(false);
    m.serverRequestCompleted(true);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(i64, 0), snap.active_requests);
    try std.testing.expectEqual(@as(u64, 2), snap.completed_requests);
    try std.testing.expectEqual(@as(u64, 1), snap.server_errors);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), snap.serverRequestSuccessRate(), 0.01);
}

test "Metrics request/response byte breakdown" {
    var m = Metrics.init();
    m.recordRequestHeaders(100);
    m.recordRequestBody(500);
    m.recordResponseHeaders(80);
    m.recordResponseBody(1000);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 100), snap.request_header_bytes);
    try std.testing.expectEqual(@as(u64, 500), snap.request_body_bytes);
    try std.testing.expectEqual(@as(u64, 80), snap.response_header_bytes);
    try std.testing.expectEqual(@as(u64, 1000), snap.response_body_bytes);
    try std.testing.expectEqual(@as(u64, 600), snap.totalRequestBytes());
    try std.testing.expectEqual(@as(u64, 1080), snap.totalResponseBytes());
}

test "Metrics computed rate getters zero state" {
    const snap = Metrics.init().snapshot();
    try std.testing.expectEqual(@as(f64, 0.0), snap.errorRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.successRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.redirectRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.clientErrorRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.serverErrorRate());
    try std.testing.expectEqual(@as(u64, 0), snap.throughputBytesPerResponse());
    try std.testing.expectEqual(@as(f64, 0.0), snap.connectionReuseRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.connectionFailureRate());
    try std.testing.expectEqual(@as(u64, 0), snap.avgDNSLatencyNs());
    try std.testing.expectEqual(@as(f64, 0.0), snap.dnsSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.dnsCacheHitRate());
    try std.testing.expectEqual(@as(u64, 0), snap.avgTLSHandshakeNs());
    try std.testing.expectEqual(@as(f64, 0.0), snap.tlsHandshakeSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.retrySuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.redirectSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.http2StreamSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.http3StreamSuccessRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.cacheHitRate());
    try std.testing.expectEqual(@as(f64, 0.0), snap.compressionRatio());
    try std.testing.expectEqual(@as(u64, 0), snap.compressionSavingsBytes());
    try std.testing.expectEqual(@as(f64, 0.0), snap.compressionSavingsPercent());
    try std.testing.expectEqual(@as(f64, 0.0), snap.rateLimitRejectionRate());
    try std.testing.expectEqual(@as(u64, 0), snap.totalSecurityRejections());
    try std.testing.expectEqual(@as(f64, 0.0), snap.serverRequestSuccessRate());
    try std.testing.expectEqual(@as(u64, 0), snap.totalRequestBytes());
    try std.testing.expectEqual(@as(u64, 0), snap.totalResponseBytes());
    try std.testing.expectEqual(@as(u64, 0), snap.avgStreamBytesPerResponse());
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

test "Metrics getters" {
    var m = Metrics.init();
    m.recordRequest();
    m.recordResponse(200, 100, 100);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.totalRequests());
    try std.testing.expectEqual(@as(u64, 1), snap.totalResponses());
    try std.testing.expectEqual(@as(i64, 0), snap.activeConnections());
    try std.testing.expectEqual(@as(u64, 0), snap.errors());
    try std.testing.expectEqual(@as(u64, 0), snap.bytesSent());
    try std.testing.expectEqual(@as(u64, 100), snap.bytesReceived());
    try std.testing.expectEqual(@as(u64, 1), snap.responses2xx());
    try std.testing.expectEqual(@as(u64, 0), snap.responses3xx());
    try std.testing.expectEqual(@as(u64, 0), snap.responses4xx());
    try std.testing.expectEqual(@as(u64, 0), snap.responses5xx());
    try std.testing.expectEqual(@as(u64, 100), snap.avgLatencyNs());
    try std.testing.expectEqual(@as(u64, 100), snap.minLatencyNs());
    try std.testing.expectEqual(@as(u64, 100), snap.maxLatencyNs());
}

test "Metrics WebSocket tracking" {
    var m = Metrics.init();
    m.wsConnectionOpened();
    m.wsConnectionOpened();
    m.wsHandshakeSuccess();
    m.wsMessageSent(0x1, 100);
    m.wsMessageSent(0x2, 200);
    m.wsMessageReceived(0x1, 50);
    m.wsPing();
    m.wsPong();
    m.wsClose();
    m.wsConnectionClosed();

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.ws_connections);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_handshake_successes);
    try std.testing.expectEqual(@as(i64, 1), snap.ws_active_connections);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_closed_connections);
    try std.testing.expectEqual(@as(u64, 2), snap.ws_messages_sent);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_messages_received);
    try std.testing.expectEqual(@as(u64, 2), snap.ws_text_messages);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_binary_messages);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_ping_frames);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_pong_frames);
    try std.testing.expectEqual(@as(u64, 1), snap.ws_close_frames);
    try std.testing.expectEqual(@as(u64, 300), snap.ws_bytes_sent);
    try std.testing.expectEqual(@as(u64, 50), snap.ws_bytes_received);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), snap.wsHandshakeSuccessRate(), 0.01);
}

test "Metrics WebSocket handshake failure rate" {
    var m = Metrics.init();
    m.wsHandshakeSuccess();
    m.wsHandshakeFailure();
    m.wsHandshakeFailure();

    const snap = m.snapshot();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) / 3.0, snap.wsHandshakeSuccessRate(), 0.01);
}

test "Metrics WebSocket zero state getters" {
    const snap = Metrics.init().snapshot();
    try std.testing.expectEqual(@as(u64, 0), snap.wsConnections());
    try std.testing.expectEqual(@as(u64, 0), snap.wsHandshakeSuccesses());
    try std.testing.expectEqual(@as(u64, 0), snap.wsHandshakeFailures());
    try std.testing.expectEqual(@as(i64, 0), snap.wsActiveConnections());
    try std.testing.expectEqual(@as(u64, 0), snap.wsClosedConnections());
    try std.testing.expectEqual(@as(u64, 0), snap.wsMessagesSent());
    try std.testing.expectEqual(@as(u64, 0), snap.wsMessagesReceived());
    try std.testing.expectEqual(@as(u64, 0), snap.wsTextMessages());
    try std.testing.expectEqual(@as(u64, 0), snap.wsBinaryMessages());
    try std.testing.expectEqual(@as(u64, 0), snap.wsPingFrames());
    try std.testing.expectEqual(@as(u64, 0), snap.wsPongFrames());
    try std.testing.expectEqual(@as(u64, 0), snap.wsCloseFrames());
    try std.testing.expectEqual(@as(u64, 0), snap.wsBytesSent());
    try std.testing.expectEqual(@as(u64, 0), snap.wsBytesReceived());
    try std.testing.expectEqual(@as(u64, 0), snap.wsProtocolErrors());
    try std.testing.expectEqual(@as(u64, 0), snap.wsOversizedFrames());
    try std.testing.expectEqual(@as(f64, 0.0), snap.wsHandshakeSuccessRate());
}
