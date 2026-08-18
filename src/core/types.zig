//! Core HTTP Types for httpx.zig
//!
//! This module provides fundamental HTTP type definitions including methods,
//! protocol versions (HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3), error types,
//! content types, and configuration structures for timeouts, retries, and redirects.
//!
//! All types are designed for zero-allocation operation where possible and
//! provide compile-time string conversion for maximum performance.

const std = @import("std");
const status_mod = @import("status.zig");

/// HTTP request methods as defined in RFC 7231 and RFC 5789.
/// Supports all standard methods plus a CUSTOM variant for extensions.
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    CUSTOM,

    /// Converts the method to its canonical string representation.
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
            .CUSTOM => "CUSTOM",
        };
    }

    /// Parses a string into a Method enum value.
    /// Returns null for unrecognized method strings.
    pub fn fromString(str: []const u8) ?Method {
        const methods = [_]struct { name: []const u8, method: Method }{
            .{ .name = "GET", .method = .GET },
            .{ .name = "POST", .method = .POST },
            .{ .name = "PUT", .method = .PUT },
            .{ .name = "DELETE", .method = .DELETE },
            .{ .name = "PATCH", .method = .PATCH },
            .{ .name = "HEAD", .method = .HEAD },
            .{ .name = "OPTIONS", .method = .OPTIONS },
            .{ .name = "TRACE", .method = .TRACE },
            .{ .name = "CONNECT", .method = .CONNECT },
        };
        for (methods) |m| {
            if (std.mem.eql(u8, str, m.name)) return m.method;
        }
        return null;
    }

    /// Returns true if the method is idempotent per RFC 7231.
    /// Idempotent methods can be safely retried without side effects.
    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            .POST, .PATCH, .CONNECT, .CUSTOM => false,
        };
    }

    /// Returns true if the method is considered safe per RFC 7231.
    /// Safe methods should not cause side effects on the server.
    pub fn isSafe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            else => false,
        };
    }

    /// Returns true if the method typically includes a request body.
    pub fn hasRequestBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }

    /// Returns true if the method expects a response body.
    pub fn hasResponseBody(self: Method) bool {
        return switch (self) {
            .HEAD => false,
            else => true,
        };
    }
};

/// HTTP protocol versions including HTTP/2 and HTTP/3 (QUIC).
pub const Version = enum {
    HTTP_1_0,
    HTTP_1_1,
    HTTP_2,
    HTTP_3,

    /// Returns the canonical string representation of the version.
    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .HTTP_1_0 => "HTTP/1.0",
            .HTTP_1_1 => "HTTP/1.1",
            .HTTP_2 => "HTTP/2",
            .HTTP_3 => "HTTP/3",
        };
    }

    /// Parses a version string into a Version enum.
    pub fn fromString(str: []const u8) ?Version {
        if (std.mem.eql(u8, str, "HTTP/1.0")) return .HTTP_1_0;
        if (std.mem.eql(u8, str, "HTTP/1.1")) return .HTTP_1_1;
        if (std.mem.eql(u8, str, "HTTP/2") or std.mem.eql(u8, str, "HTTP/2.0")) return .HTTP_2;
        if (std.mem.eql(u8, str, "HTTP/3") or std.mem.eql(u8, str, "HTTP/3.0")) return .HTTP_3;
        return null;
    }

    /// Returns true if the version supports multiplexing.
    pub fn supportsMultiplexing(self: Version) bool {
        return self == .HTTP_2 or self == .HTTP_3;
    }

    /// Returns true if the version supports server push.
    pub fn supportsServerPush(self: Version) bool {
        return self == .HTTP_2;
    }

    /// Returns true if the version uses QUIC transport.
    pub fn usesQUIC(self: Version) bool {
        return self == .HTTP_3;
    }

    /// Returns true if the version requires TLS by specification.
    pub fn requiresTLS(self: Version) bool {
        return self == .HTTP_2 or self == .HTTP_3;
    }
};

/// HTTP error types with context information for debugging.
pub const HTTPError = error{
    ConnectionFailed,
    ConnectionReset,
    ConnectionTimeout,
    InvalidUri,
    InvalidResponse,
    InvalidHeader,
    InvalidChunkSize,
    TooManyRedirects,
    TLSHandshakeFailed,
    TLSCertificateError,
    TLSError,
    TLSTimeout,
    ResponseTooLarge,
    RequestTooLarge,
    Timeout,
    RequestTimeout,
    ReadTimeout,
    WriteTimeout,
    DNSTimeout,
    ProxyTimeout,
    HeaderTimeout,
    IdleTimeout,
    ShutdownTimeout,
    Cancelled,
    HostUnreachable,
    DNSResolutionFailed,
    ProtocolError,
    StreamError,
    FlowControlError,
    FrameError,
    CompressionError,
    HTTP2Error,
    HTTP3Error,
    QUICError,
    OutOfMemory,
};

/// Common MIME content types for HTTP messages.
pub const ContentType = enum {
    text_plain,
    text_html,
    text_css,
    text_javascript,
    application_json,
    application_xml,
    application_octet_stream,
    application_form_urlencoded,
    multipart_form_data,
    image_png,
    image_jpeg,
    image_gif,
    image_webp,
    image_svg,

    /// Returns the MIME type string.
    pub fn toString(self: ContentType) []const u8 {
        return switch (self) {
            .text_plain => "text/plain",
            .text_html => "text/html",
            .text_css => "text/css",
            .text_javascript => "text/javascript",
            .application_json => "application/json",
            .application_xml => "application/xml",
            .application_octet_stream => "application/octet-stream",
            .application_form_urlencoded => "application/x-www-form-urlencoded",
            .multipart_form_data => "multipart/form-data",
            .image_png => "image/png",
            .image_jpeg => "image/jpeg",
            .image_gif => "image/gif",
            .image_webp => "image/webp",
            .image_svg => "image/svg+xml",
        };
    }

    /// Parses a MIME type string into a ContentType enum.
    /// Matches the base MIME type, ignoring parameters (e.g., "; charset=utf-8").
    pub fn fromString(str: []const u8) ?ContentType {
        const types = [_]struct { name: []const u8, ct: ContentType }{
            .{ .name = "text/plain", .ct = .text_plain },
            .{ .name = "text/html", .ct = .text_html },
            .{ .name = "text/css", .ct = .text_css },
            .{ .name = "text/javascript", .ct = .text_javascript },
            .{ .name = "application/json", .ct = .application_json },
            .{ .name = "application/xml", .ct = .application_xml },
            .{ .name = "application/octet-stream", .ct = .application_octet_stream },
            .{ .name = "application/x-www-form-urlencoded", .ct = .application_form_urlencoded },
            .{ .name = "multipart/form-data", .ct = .multipart_form_data },
            .{ .name = "image/png", .ct = .image_png },
            .{ .name = "image/jpeg", .ct = .image_jpeg },
            .{ .name = "image/gif", .ct = .image_gif },
            .{ .name = "image/webp", .ct = .image_webp },
            .{ .name = "image/svg+xml", .ct = .image_svg },
        };
        for (types) |t| {
            if (std.mem.startsWith(u8, str, t.name)) {
                // Match exactly, or match up to a ';' parameter separator
                if (str.len == t.name.len) return t.ct;
                if (str.len > t.name.len and str[t.name.len] == ';') return t.ct;
            }
        }
        return null;
    }
};

/// Transfer encoding types for HTTP message bodies.
pub const TransferEncoding = enum {
    identity,
    chunked,
    gzip,
    deflate,
    br,

    pub fn toString(self: TransferEncoding) []const u8 {
        return switch (self) {
            .identity => "identity",
            .chunked => "chunked",
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
        };
    }
};

/// Timeout configuration for HTTP operations in milliseconds.
pub const Timeouts = struct {
    connect_ms: u64 = 30_000,
    read_ms: u64 = 30_000,
    write_ms: u64 = 30_000,
    keep_alive_ms: u64 = 60_000,
    idle_ms: u64 = 120_000,
    request_ms: u64 = 0,
    /// TLS handshake timeout in milliseconds. 0 means use connect_ms.
    tls_handshake_ms: u64 = 0,
    /// Header reception timeout in milliseconds. 0 means use read_ms.
    header_ms: u64 = 0,
    /// Shutdown timeout in milliseconds. 0 means 5000.
    shutdown_ms: u64 = 0,

    /// Creates a timeout configuration with all values set uniformly.
    pub fn uniform(ms: u64) Timeouts {
        return .{
            .connect_ms = ms,
            .read_ms = ms,
            .write_ms = ms,
            .keep_alive_ms = ms * 2,
            .idle_ms = ms * 4,
        };
    }

    /// Creates timeouts optimized for fast operations.
    pub fn fast() Timeouts {
        return uniform(5_000);
    }

    /// Creates timeouts for long-running operations.
    pub fn slow() Timeouts {
        return uniform(120_000);
    }

    /// Disables all timeouts (use with caution).
    pub fn none() Timeouts {
        return .{
            .connect_ms = 0,
            .read_ms = 0,
            .write_ms = 0,
            .keep_alive_ms = 0,
            .idle_ms = 0,
        };
    }

    /// Returns the effective TLS handshake timeout.
    pub fn effectiveTlsHandshakeMs(self: Timeouts) u64 {
        if (self.tls_handshake_ms > 0) return self.tls_handshake_ms;
        return self.connect_ms;
    }

    /// Returns the effective header timeout.
    pub fn effectiveHeaderMs(self: Timeouts) u64 {
        if (self.header_ms > 0) return self.header_ms;
        return self.read_ms;
    }

    /// Returns the effective shutdown timeout.
    pub fn effectiveShutdownMs(self: Timeouts) u64 {
        if (self.shutdown_ms > 0) return self.shutdown_ms;
        return 5_000;
    }
};

/// Cancellation token for in-flight operations.
/// Thread-safe: uses atomic operations for cancellation signal.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn init() @This() {
        return .{};
    }

    /// Signals cancellation. Thread-safe.
    pub fn cancel(self: *@This()) void {
        self.cancelled.store(true, .release);
    }

    /// Returns true if cancellation has been requested. Thread-safe.
    pub fn isCancelled(self: *const @This()) bool {
        return self.cancelled.load(.acquire);
    }

    /// Returns error.Cancelled if cancellation has been requested.
    /// Use this in I/O loops: try token.throwIfCancelled();
    pub fn throwIfCancelled(self: *const @This()) error{Cancelled}!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

/// Retry policy configuration with exponential backoff support.
pub const RetryPolicy = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30_000,
    backoff_multiplier: f64 = 2.0,
    retry_on_status: []const u16 = &[_]u16{ 429, 500, 502, 503, 504 },
    retry_on_connection_error: bool = true,
    retry_only_idempotent: bool = true,
    /// Jitter factor (0.0 = no jitter, 1.0 = full jitter). Default 0.3 for decorrelated jitter.
    jitter: f64 = 0.3,

    /// Calculates the delay for a given retry attempt using exponential backoff with jitter.
    pub fn calculateDelay(self: RetryPolicy, attempt: u32) u64 {
        if (attempt == 0) return 0;
        const multiplier = std.math.pow(f64, self.backoff_multiplier, @as(f64, @floatFromInt(attempt - 1)));
        const base_delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.initial_delay_ms)) * multiplier));
        const clamped = @min(base_delay, self.max_delay_ms);

        // Apply decorrelated jitter: delay = random(base * (1 - jitter), base * (1 + jitter))
        if (self.jitter > 0.0) {
            var rand_bytes: [8]u8 = undefined;
            @import("../io/any_io.zig").defaultIo().random(&rand_bytes);
            const rand_val = @as(f64, @floatFromInt(@as(u64, @bitCast(rand_bytes)))) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
            const jitter_range = @as(f64, @floatFromInt(clamped)) * self.jitter;
            const jitter_offset = jitter_range * (2.0 * rand_val - 1.0); // [-jitter_range, +jitter_range]
            const result = @as(i64, @intFromFloat(@as(f64, @floatFromInt(clamped)) + jitter_offset));
            return @intCast(@max(0, @min(result, @as(i64, @intCast(self.max_delay_ms)))));
        }
        return clamped;
    }

    /// Returns true if the given status code should trigger a retry.
    pub fn shouldRetryStatus(self: RetryPolicy, status: u16) bool {
        for (self.retry_on_status) |s| {
            if (s == status) return true;
        }
        return false;
    }

    /// Creates a policy that never retries.
    pub fn noRetry() RetryPolicy {
        return .{ .max_retries = 0 };
    }

    /// Creates an aggressive retry policy for critical requests.
    pub fn aggressive() RetryPolicy {
        return .{
            .max_retries = 5,
            .initial_delay_ms = 500,
            .backoff_multiplier = 1.5,
        };
    }
};

/// Redirect policy configuration for HTTP clients.
pub const RedirectPolicy = struct {
    max_redirects: u32 = 10,
    follow_redirects: bool = true,
    preserve_method: bool = false,
    preserve_headers: bool = true,
    allow_cross_origin: bool = true,

    /// Returns the appropriate method to use after a redirect.
    pub fn getRedirectMethod(self: RedirectPolicy, status: u16, original: Method) Method {
        // 303 See Other always changes to GET per RFC 7231, regardless of policy
        if (status == status_mod.StatusCode.SEE_OTHER) return .GET;
        if (self.preserve_method) return original;
        return switch (status) {
            status_mod.StatusCode.MOVED_PERMANENTLY, status_mod.StatusCode.FOUND => .GET,
            status_mod.StatusCode.TEMPORARY_REDIRECT, status_mod.StatusCode.PERMANENT_REDIRECT => original,
            else => original,
        };
    }

    /// Creates a policy that doesn't follow redirects.
    pub fn noFollow() RedirectPolicy {
        return .{ .follow_redirects = false };
    }

    /// Creates a strict policy that preserves method on redirects.
    pub fn strict() RedirectPolicy {
        return .{ .preserve_method = true };
    }
};

/// HTTP/2 specific settings as defined in RFC 7540.
pub const HTTP2Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,
};

/// HTTP/3 and QUIC specific settings.
pub const HTTP3Settings = struct {
    max_field_section_size: u64 = 8192,
    qpack_max_table_capacity: u64 = 4096,
    qpack_blocked_streams: u64 = 100,
    enable_connect_protocol: bool = true,
    enable_datagrams: bool = false,
};

/// Supported proxy transport types.
pub const ProxyKind = enum {
    http,
    socks5h,
};

/// Proxy configuration settings.
pub const Proxy = struct {
    kind: ProxyKind = .http,
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    no_proxy: ?[]const u8 = null,

    pub fn shouldBypassProxy(proxy: Proxy, hostname: []const u8) bool {
        const list = proxy.no_proxy orelse return false;
        if (list.len == 0) return false;

        var remaining = list;
        while (remaining.len > 0) {
            const next_comma = std.mem.indexOf(u8, remaining, ",");
            const entry_raw = if (next_comma) |idx| remaining[0..idx] else remaining;
            const entry = std.mem.trim(u8, entry_raw, " \t\r\n");

            if (entry.len > 0) {
                if (std.mem.eql(u8, entry, "*")) return true;

                if (std.ascii.eqlIgnoreCase(entry, hostname)) return true;

                if (entry.len > 0 and entry[0] == '.') {
                    if (hostname.len >= entry.len) {
                        const suffix = hostname[hostname.len - entry.len ..];
                        if (std.ascii.eqlIgnoreCase(suffix, entry)) return true;
                    }
                } else {
                    if (hostname.len > entry.len + 1) {
                        const dot_pos = hostname.len - entry.len - 1;
                        if (hostname[dot_pos] == '.' and std.ascii.eqlIgnoreCase(hostname[dot_pos + 1 ..], entry)) {
                            return true;
                        }
                    }
                }
            }

            if (next_comma) |idx| {
                remaining = remaining[idx + 1 ..];
            } else {
                break;
            }
        }

        return false;
    }
};

test "Method.fromString" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expect(Method.fromString("INVALID") == null);
}

test "Method properties" {
    try std.testing.expect(Method.GET.isIdempotent());
    try std.testing.expect(Method.GET.isSafe());
    try std.testing.expect(!Method.POST.isIdempotent());
    try std.testing.expect(Method.POST.hasRequestBody());
}

test "Version.fromString" {
    try std.testing.expectEqual(Version.HTTP_1_1, Version.fromString("HTTP/1.1").?);
    try std.testing.expectEqual(Version.HTTP_2, Version.fromString("HTTP/2").?);
    try std.testing.expectEqual(Version.HTTP_3, Version.fromString("HTTP/3").?);
}

test "Version properties" {
    try std.testing.expect(Version.HTTP_2.supportsMultiplexing());
    try std.testing.expect(Version.HTTP_3.usesQUIC());
    try std.testing.expect(!Version.HTTP_1_1.supportsMultiplexing());
}

test "ContentType.fromString" {
    try std.testing.expectEqual(ContentType.application_json, ContentType.fromString("application/json").?);
    try std.testing.expectEqual(ContentType.text_html, ContentType.fromString("text/html; charset=utf-8").?);
}

test "RetryPolicy.calculateDelay" {
    const policy = RetryPolicy{ .jitter = 0.0 }; // No jitter for deterministic test
    try std.testing.expectEqual(@as(u64, 0), policy.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 1000), policy.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 2000), policy.calculateDelay(2));
}

test "RetryPolicy.calculateDelay with jitter" {
    const policy = RetryPolicy{ .jitter = 0.5 };
    try std.testing.expectEqual(@as(u64, 0), policy.calculateDelay(0));
    const delay = policy.calculateDelay(1);
    // With 0.5 jitter, delay should be in range [500, 1500]
    try std.testing.expect(delay >= 500 and delay <= 1500);
}

test "RedirectPolicy.getRedirectMethod" {
    const policy = RedirectPolicy{};
    // Default: 301/302/303 change POST to GET
    try std.testing.expectEqual(Method.GET, policy.getRedirectMethod(301, .POST));
    try std.testing.expectEqual(Method.GET, policy.getRedirectMethod(302, .POST));
    try std.testing.expectEqual(Method.GET, policy.getRedirectMethod(303, .POST));
    // Default: 307/308 preserve method
    try std.testing.expectEqual(Method.POST, policy.getRedirectMethod(307, .POST));
    try std.testing.expectEqual(Method.POST, policy.getRedirectMethod(308, .POST));

    // Strict: preserves method for 301/302/307/308
    const strict = RedirectPolicy.strict();
    try std.testing.expectEqual(Method.POST, strict.getRedirectMethod(301, .POST));
    try std.testing.expectEqual(Method.POST, strict.getRedirectMethod(302, .POST));
    try std.testing.expectEqual(Method.POST, strict.getRedirectMethod(307, .POST));
    try std.testing.expectEqual(Method.POST, strict.getRedirectMethod(308, .POST));
    // Strict: 303 ALWAYS changes to GET per RFC 7231
    try std.testing.expectEqual(Method.GET, strict.getRedirectMethod(303, .POST));
}

test "CancellationToken basic" {
    var token = CancellationToken.init();
    try std.testing.expect(!token.isCancelled());

    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "CancellationToken throwIfCancelled" {
    var token = CancellationToken.init();
    // Not cancelled yet - should return without error.
    token.throwIfCancelled() catch unreachable;

    token.cancel();
    // Now cancelled - should return error.Cancelled.
    const result = token.throwIfCancelled();
    try std.testing.expectError(error.Cancelled, result);
}

test "Timeouts effective values" {
    const t = Timeouts{
        .connect_ms = 10_000,
        .read_ms = 20_000,
        .tls_handshake_ms = 0,
        .header_ms = 0,
        .shutdown_ms = 0,
    };
    // When tls_handshake_ms is 0, falls back to connect_ms.
    try std.testing.expectEqual(@as(u64, 10_000), t.effectiveTlsHandshakeMs());
    // When header_ms is 0, falls back to read_ms.
    try std.testing.expectEqual(@as(u64, 20_000), t.effectiveHeaderMs());
    // When shutdown_ms is 0, defaults to 5000.
    try std.testing.expectEqual(@as(u64, 5_000), t.effectiveShutdownMs());

    const t2 = Timeouts{
        .connect_ms = 10_000,
        .read_ms = 20_000,
        .tls_handshake_ms = 15_000,
        .header_ms = 25_000,
        .shutdown_ms = 30_000,
    };
    try std.testing.expectEqual(@as(u64, 15_000), t2.effectiveTlsHandshakeMs());
    try std.testing.expectEqual(@as(u64, 25_000), t2.effectiveHeaderMs());
    try std.testing.expectEqual(@as(u64, 30_000), t2.effectiveShutdownMs());
}

test "Timeouts presets" {
    const fast = Timeouts.fast();
    try std.testing.expectEqual(@as(u64, 5_000), fast.connect_ms);
    try std.testing.expectEqual(@as(u64, 10_000), fast.keep_alive_ms);

    const slow = Timeouts.slow();
    try std.testing.expectEqual(@as(u64, 120_000), slow.connect_ms);

    const none = Timeouts.none();
    try std.testing.expectEqual(@as(u64, 0), none.connect_ms);
    try std.testing.expectEqual(@as(u64, 0), none.read_ms);
}

/// Resource limits for HTTP operations to prevent abuse and resource exhaustion.
pub const ResourceLimits = struct {
    max_url_length: usize = 8192,
    max_header_size: usize = 8192,
    max_header_count: usize = 100,
    max_request_body_size: usize = 10 * 1024 * 1024,
    max_response_body_size: usize = 50 * 1024 * 1024,
    max_decompressed_size: usize = 100 * 1024 * 1024,
    max_connections: u32 = 1024,
    max_concurrent_streams: u32 = 100,
    max_dns_response_size: usize = 4096,
};

test "ResourceLimits defaults" {
    const limits = ResourceLimits{};
    try std.testing.expectEqual(@as(usize, 8192), limits.max_url_length);
    try std.testing.expectEqual(@as(usize, 8192), limits.max_header_size);
    try std.testing.expectEqual(@as(usize, 100), limits.max_header_count);
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), limits.max_request_body_size);
    try std.testing.expectEqual(@as(usize, 50 * 1024 * 1024), limits.max_response_body_size);
    try std.testing.expectEqual(@as(usize, 100 * 1024 * 1024), limits.max_decompressed_size);
    try std.testing.expectEqual(@as(u32, 1024), limits.max_connections);
    try std.testing.expectEqual(@as(u32, 100), limits.max_concurrent_streams);
    try std.testing.expectEqual(@as(usize, 4096), limits.max_dns_response_size);
}

test "ResourceLimits custom" {
    const limits = ResourceLimits{
        .max_url_length = 4096,
        .max_connections = 512,
    };
    try std.testing.expectEqual(@as(usize, 4096), limits.max_url_length);
    try std.testing.expectEqual(@as(u32, 512), limits.max_connections);
    try std.testing.expectEqual(@as(usize, 8192), limits.max_header_size);
}

test "HTTPError new timeout variants" {
    // Ensure the new timeout error types compile as valid HTTPError variants.
    const RequestTimeout = error.RequestTimeout;
    const TLSTimeout = error.TLSTimeout;
    const DNSTimeout = error.DNSTimeout;
    const HeaderTimeout = error.HeaderTimeout;
    const IdleTimeout = error.IdleTimeout;
    const ShutdownTimeout = error.ShutdownTimeout;
    try std.testing.expect(@as(HTTPError, RequestTimeout) == error.RequestTimeout);
    try std.testing.expect(@as(HTTPError, TLSTimeout) == error.TLSTimeout);
    try std.testing.expect(@as(HTTPError, DNSTimeout) == error.DNSTimeout);
    try std.testing.expect(@as(HTTPError, HeaderTimeout) == error.HeaderTimeout);
    try std.testing.expect(@as(HTTPError, IdleTimeout) == error.IdleTimeout);
    try std.testing.expect(@as(HTTPError, ShutdownTimeout) == error.ShutdownTimeout);
}
