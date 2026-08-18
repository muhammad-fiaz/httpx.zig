const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try settingsEnforcementExample(allocator);
    try goawayAndRstStreamExample(allocator);
    try hpackSecurityExample(allocator);
    try trailerExample(allocator);
    try tlsAndAlpnExample(allocator);
}

fn settingsEnforcementExample(allocator: std.mem.Allocator) !void {
    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    const peer_settings = httpx.Http2Connection.Settings{
        .header_table_size = 4096,
        .enable_push = false,
        .max_concurrent_streams = 3,
        .initial_window_size = 32768,
        .max_frame_size = 16384,
        .max_header_list_size = 65535,
    };

    try manager.applyPeerSettings(peer_settings);

    std.debug.print("Applied peer settings:\n", .{});
    std.debug.print("  max_concurrent_streams: {d}\n", .{manager.max_concurrent_streams});
    std.debug.print("  max_frame_size: {d}\n", .{manager.peer_settings.max_frame_size});
    std.debug.print("  initial_window_size: {d}\n", .{manager.peer_settings.initial_window_size});

    std.debug.print("\nCan open stream (0 active): {s}\n", .{
        if (manager.canOpenStream()) "yes" else "no",
    });

    for (0..3) |_| {
        const s = try manager.createStream();
        try s.open();
        std.debug.print("Opened stream {d} (active: {d})\n", .{ s.id, manager.activeStreamCount() });
    }

    std.debug.print("Can open stream (3 active, limit 3): {s}\n", .{
        if (manager.canOpenStream()) "yes" else "no",
    });

    const result = manager.validateFrameSize(16384);
    std.debug.print("\nFrame size 16384 valid: {s}\n", .{
        if (result) |_| "yes" else |_| "no",
    });

    const oversized = manager.validateFrameSize(16385);
    std.debug.print("Frame size 16385 valid: {s}\n", .{
        if (oversized) |_| "yes" else |_| "no",
    });

    const stream = try manager.createStream();
    try stream.open();
    std.debug.print("\nStream {d} send window after window size change: {d}\n", .{
        stream.id,
        stream.send_window,
    });

    std.debug.print("\n", .{});
}

fn goawayAndRstStreamExample(allocator: std.mem.Allocator) !void {
    const goaway_frame = try httpx.stream.buildGoawayFrame(
        7,
        .no_error,
        "server shutting down",
        allocator,
    );
    defer allocator.free(goaway_frame);

    std.debug.print("GOAWAY frame: {d} bytes\n", .{goaway_frame.len});

    const header = httpx.Http2FrameHeader.parse(goaway_frame[0..9].*);
    std.debug.print("  type: {s}, stream: {d}\n", .{
        @tagName(header.frame_type),
        header.stream_id,
    });

    const parsed = try httpx.stream.parseGoawayPayload(goaway_frame[9..], allocator);
    if (parsed.debug_data) |dd| {
        defer allocator.free(dd);
        std.debug.print("  last_stream_id: {d}\n", .{parsed.last_stream_id});
        std.debug.print("  error_code: {s}\n", .{@tagName(parsed.error_code)});
        std.debug.print("  debug_data: \"{s}\"\n", .{dd});
    }

    const rst_frame = httpx.stream.buildRstStreamFrame(5, .cancel);
    std.debug.print("\nRST_STREAM frame: {d} bytes\n", .{rst_frame.len});

    const rst_header = httpx.Http2FrameHeader.parse(rst_frame[0..9].*);
    std.debug.print("  type: {s}, stream: {d}\n", .{
        @tagName(rst_header.frame_type),
        rst_header.stream_id,
    });

    const error_code = try httpx.stream.parseRstStreamPayload(rst_frame[9..13]);
    std.debug.print("  error_code: {s}\n", .{@tagName(error_code)});

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

fn hpackSecurityExample(allocator: std.mem.Allocator) !void {
    var auth_out = std.ArrayList(u8).empty;
    defer auth_out.deinit(allocator);
    try httpx.hpack.encodeHeaderWithoutIndexing(
        null,
        "authorization",
        "Bearer secret-token-12345",
        allocator,
        &auth_out,
    );
    std.debug.print("Authorization (Without Indexing): {d} bytes\n", .{auth_out.items.len});

    var cookie_out = std.ArrayList(u8).empty;
    defer cookie_out.deinit(allocator);
    try httpx.hpack.encodeHeaderNeverIndexed(
        null,
        "cookie",
        "session=abc123; token=xyz789",
        allocator,
        &cookie_out,
    );
    std.debug.print("Cookie (Never Indexed): {d} bytes\n", .{cookie_out.items.len});

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

fn trailerExample(allocator: std.mem.Allocator) !void {
    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    const trailer_headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = "x-checksum", .value = "sha256-abc123" },
        .{ .name = "x-content-length", .value = "4096" },
    };

    const trailer_result = try httpx.stream.buildHeadersAndContinuations(
        &manager,
        1,
        &trailer_headers,
        null,
        16384,
        true,
        allocator,
    );
    defer allocator.free(trailer_result);

    std.debug.print("Trailer HEADERS frame: {d} bytes\n", .{trailer_result.len});

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

fn tlsAndAlpnExample(allocator: std.mem.Allocator) !void {
    const tls_cfg = httpx.tls.TlsConfig.withH2(allocator);
    std.debug.print("TlsConfig.withH2():\n", .{});
    std.debug.print("  wantsHttp2: {s}\n", .{if (tls_cfg.wantsHTTP2()) "true" else "false"});
    std.debug.print("  verify_server: {s}\n", .{if (tls_cfg.verify_server) "true" else "false"});
    std.debug.print("  primary ALPN protocol: {s}\n", .{tls_cfg.alpn_protocols[0]});

    var strict_cfg = httpx.tls.TlsConfig.init(allocator);
    strict_cfg.verify_server = false;
    std.debug.print("\nInsecure TlsConfig:\n", .{});
    std.debug.print("  verify_server: {s}\n", .{if (strict_cfg.verify_server) "true" else "false"});

    std.debug.print("\n", .{});
}
