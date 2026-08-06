//! HTTP/2 Advanced Features for httpx.zig
//!
//! This example demonstrates the new HTTP/2 production features:
//! - SETTINGS enforcement (MAX_CONCURRENT_STREAMS, MAX_FRAME_SIZE, INITIAL_WINDOW_SIZE)
//! - GOAWAY and RST_STREAM frame construction
//! - HPACK Without Indexing / Never Indexed representations
//! - Connection pooling concepts
//! - Trailer support
//!
//! These features make the HTTP/2 implementation production-ready.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== httpx.zig HTTP/2 Advanced Features ===\n\n", .{});

    try settingsEnforcementExample(allocator);
    try goawayAndRstStreamExample(allocator);
    try hpackSecurityExample(allocator);
    try trailerExample(allocator);
    try tlsAndAlpnExample(allocator);

    std.debug.print("\n=== All HTTP/2 advanced examples completed ===\n", .{});
}

/// Demonstrates SETTINGS enforcement: MAX_CONCURRENT_STREAMS, MAX_FRAME_SIZE,
/// and INITIAL_WINDOW_SIZE are parsed and applied to the stream manager.
fn settingsEnforcementExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- SETTINGS Enforcement ---\n", .{});

    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    // Simulate receiving peer SETTINGS with custom values
    const peer_settings = httpx.Http2Connection.Http2ConnectionSettings{
        .header_table_size = 4096,
        .enable_push = false,
        .max_concurrent_streams = 3,
        .initial_window_size = 32768,
        .max_frame_size = 16384,
        .max_header_list_size = 65535,
    };

    // Apply peer settings - this enforces the values
    try manager.applyPeerSettings(peer_settings);

    std.debug.print("Applied peer settings:\n", .{});
    std.debug.print("  max_concurrent_streams: {d}\n", .{manager.max_concurrent_streams});
    std.debug.print("  max_frame_size: {d}\n", .{manager.peer_settings.max_frame_size});
    std.debug.print("  initial_window_size: {d}\n", .{manager.peer_settings.initial_window_size});

    // canOpenStream respects MAX_CONCURRENT_STREAMS
    std.debug.print("\nCan open stream (0 active): {s}\n", .{
        if (manager.canOpenStream()) "yes" else "no",
    });

    // Create and open streams up to the limit
    for (0..3) |_| {
        const s = try manager.createStream();
        try s.open();
        std.debug.print("Opened stream {d} (active: {d})\n", .{ s.id, manager.activeStreamCount() });
    }

    // Should not be able to open more
    std.debug.print("Can open stream (3 active, limit 3): {s}\n", .{
        if (manager.canOpenStream()) "yes" else "no",
    });

    // validateFrameSize checks against peer's MAX_FRAME_SIZE
    const result = manager.validateFrameSize(16384);
    std.debug.print("\nFrame size 16384 valid: {s}\n", .{
        if (result) |_| "yes" else |_| "no",
    });

    const oversized = manager.validateFrameSize(16385);
    std.debug.print("Frame size 16385 valid: {s}\n", .{
        if (oversized) |_| "yes" else |_| "no",
    });

    // Stream send windows are adjusted when INITIAL_WINDOW_SIZE changes
    const stream = try manager.createStream();
    try stream.open();
    std.debug.print("\nStream {d} send window after window size change: {d}\n", .{
        stream.id,
        stream.send_window,
    });

    std.debug.print("\n", .{});
}

/// Demonstrates GOAWAY and RST_STREAM frame construction.
fn goawayAndRstStreamExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- GOAWAY and RST_STREAM ---\n", .{});

    // Build a GOAWAY frame for clean shutdown
    const goaway_frame = try httpx.stream.buildGoawayFrame(
        7, // Last processed stream ID
        .no_error,
        "server shutting down",
        allocator,
    );
    defer allocator.free(goaway_frame);

    std.debug.print("GOAWAY frame: {d} bytes\n", .{goaway_frame.len});

    // Parse the frame header
    const header = httpx.Http2FrameHeader.parse(goaway_frame[0..9].*);
    std.debug.print("  type: {s}, stream: {d}\n", .{
        @tagName(header.frame_type),
        header.stream_id,
    });

    // Parse the GOAWAY payload
    const parsed = try httpx.stream.parseGoawayPayload(goaway_frame[9..], allocator);
    if (parsed.debug_data) |dd| {
        defer allocator.free(dd);
        std.debug.print("  last_stream_id: {d}\n", .{parsed.last_stream_id});
        std.debug.print("  error_code: {s}\n", .{@tagName(parsed.error_code)});
        std.debug.print("  debug_data: \"{s}\"\n", .{dd});
    }

    // Build a RST_STREAM frame to cancel a stream
    const rst_frame = httpx.stream.buildRstStreamFrame(5, .cancel);
    std.debug.print("\nRST_STREAM frame: {d} bytes\n", .{rst_frame.len});

    const rst_header = httpx.Http2FrameHeader.parse(rst_frame[0..9].*);
    std.debug.print("  type: {s}, stream: {d}\n", .{
        @tagName(rst_header.frame_type),
        rst_header.stream_id,
    });

    const error_code = try httpx.stream.parseRstStreamPayload(rst_frame[9..13]);
    std.debug.print("  error_code: {s}\n", .{@tagName(error_code)});

    // Build a GOAWAY with protocol error
    const goaway_err = try httpx.stream.buildGoawayFrame(
        3,
        .protocol_error,
        null,
        allocator,
    );
    defer allocator.free(goaway_err);
    std.debug.print("\nGOAWAY (error): {d} bytes, no debug data\n", .{goaway_err.len});

    std.debug.print("\n", .{});
}

/// Demonstrates HPACK Without Indexing and Never Indexed representations
/// for security-sensitive headers.
fn hpackSecurityExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- HPACK Security: Without Indexing / Never Indexed ---\n", .{});

    // Authorization header: should use Without Indexing (volatile, but not
    // at high risk of observation). This encodes the header without adding
    // it to the dynamic table.
    var auth_out = std.ArrayList(u8).empty;
    defer auth_out.deinit(allocator);
    try httpx.hpack.encodeHeaderWithoutIndexing(
        null, // literal name (not in static table)
        "authorization",
        "Bearer secret-token-12345",
        allocator,
        &auth_out,
    );
    std.debug.print("Authorization (Without Indexing): {d} bytes\n", .{auth_out.items.len});

    // Cookie header: should use Never Indexed (contains credentials that
    // must never be cached in intermediary dynamic tables).
    var cookie_out = std.ArrayList(u8).empty;
    defer cookie_out.deinit(allocator);
    try httpx.hpack.encodeHeaderNeverIndexed(
        null, // literal name
        "cookie",
        "session=abc123; token=xyz789",
        allocator,
        &cookie_out,
    );
    std.debug.print("Cookie (Never Indexed): {d} bytes\n", .{cookie_out.items.len});

    // Compare with standard incremental indexing (would pollute the dynamic table)
    var ctx2 = httpx.HpackContext.init(allocator);
    defer ctx2.deinit();

    const normal_headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = "authorization", .value = "Bearer secret-token-12345" },
    };
    const normal_encoded = try httpx.hpack.encodeHeaders(&ctx2, &normal_headers, allocator);
    defer allocator.free(normal_encoded);

    std.debug.print("Authorization (Incremental): {d} bytes\n", .{normal_encoded.len});

    std.debug.print("\nKey difference: Without Indexing/Never Indexed do NOT\n", .{});
    std.debug.print("  add entries to the dynamic table, preventing HPACK\n", .{});
    std.debug.print("  bomb attacks and accidental cache pollution.\n", .{});

    std.debug.print("\n", .{});
}

/// Demonstrates HTTP/2 trailer support.
fn trailerExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- HTTP/2 Trailer Support ---\n", .{});

    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    // Build a trailer HEADERS frame (END_STREAM flag set)
    // Trailers are sent after the DATA frames to provide
    // request/response integrity information.
    const trailer_headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = "x-checksum", .value = "sha256-abc123" },
        .{ .name = "x-content-length", .value = "4096" },
    };

    // Build HEADERS frame with END_STREAM for trailers
    const trailer_result = try httpx.stream.buildHeadersAndContinuations(
        &manager,
        1, // stream ID
        &trailer_headers,
        null, // no priority
        16384, // max frame size
        true, // END_STREAM = true for trailers
        allocator,
    );
    defer allocator.free(trailer_result);

    std.debug.print("Trailer HEADERS frame: {d} bytes\n", .{trailer_result.len});

    // Parse the frame header
    const header = httpx.Http2FrameHeader.parse(trailer_result[0..9].*);
    std.debug.print("  type: {s}, stream: {d}\n", .{
        @tagName(header.frame_type),
        header.stream_id,
    });
    std.debug.print("  flags: 0x{x} (END_STREAM={s})\n", .{
        header.flags,
        if (header.flags & 0x01 != 0) "yes" else "no",
    });

    std.debug.print("\nTrailers are sent as HEADERS frames after all DATA frames\n", .{});
    std.debug.print("  with the END_STREAM flag set. This signals that no more\n", .{});
    std.debug.print("  data will be sent on this stream.\n", .{});

    std.debug.print("\n", .{});
}

/// Demonstrates TlsConfig ALPN and allow_truncation_attacks configuration.
fn tlsAndAlpnExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- TLS Config & ALPN Negotiation ---\n", .{});

    const tls_cfg = httpx.tls.TlsConfig.withH2(allocator);
    std.debug.print("TlsConfig.withH2():\n", .{});
    std.debug.print("  wantsHttp2: {s}\n", .{if (tls_cfg.wantsHttp2()) "true" else "false"});
    std.debug.print("  verify_server: {s}\n", .{if (tls_cfg.verify_server) "true" else "false"});
    std.debug.print("  primary ALPN protocol: {s}\n", .{tls_cfg.alpn_protocols[0]});

    var strict_cfg = httpx.tls.TlsConfig.init(allocator);
    strict_cfg.verify_server = false;
    std.debug.print("\nInsecure TlsConfig:\n", .{});
    std.debug.print("  verify_server: {s}\n", .{if (strict_cfg.verify_server) "true" else "false"});

    std.debug.print("\n", .{});
}
