const std = @import("std");
const builtin = @import("builtin");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try hpackExample(allocator);

    try streamExample(allocator);

    try framingExample(allocator);

    try flowControlExample(allocator);
}

fn hpackExample(allocator: std.mem.Allocator) !void {
    var ctx = httpx.HpackContext.init(allocator);
    defer ctx.deinit();

    const headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/api/users" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "httpbun.com" },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "user-agent", .value = httpx.DEFAULT_USER_AGENT },
    };

    const encoded = try httpx.hpack.encodeHeaders(&ctx, &headers, allocator);
    defer allocator.free(encoded);

    std.debug.print("Original headers: {d} fields\n", .{headers.len});
    std.debug.print("Encoded size: {d} bytes\n", .{encoded.len});

    var original_size: usize = 0;
    for (headers) |h| {
        original_size += h.name.len + h.value.len + 4;
    }
    const ratio = @as(f32, @floatFromInt(encoded.len)) / @as(f32, @floatFromInt(original_size)) * 100;
    std.debug.print("Compression ratio: {d:.1}%\n", .{ratio});

    var decode_ctx = httpx.HpackContext.init(allocator);
    defer decode_ctx.deinit();

    const decoded = try httpx.hpack.decodeHeaders(&decode_ctx, encoded, allocator);
    defer {
        for (decoded) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(decoded);
    }

    std.debug.print("Decoded {d} headers:\n", .{decoded.len});
    for (decoded) |h| {
        std.debug.print("  {s}: {s}\n", .{ h.name, h.value });
    }

    var buf: [10]u8 = undefined;
    const len = try httpx.hpack.encodeInteger(1337, 5, &buf);
    std.debug.print("Integer 1337 encoded in {d} bytes with 5-bit prefix\n", .{len});

    const result = try httpx.hpack.decodeInteger(buf[0..len], 5);
    std.debug.print("Decoded back to: {d}\n\n", .{result.value});
}

fn streamExample(allocator: std.mem.Allocator) !void {
    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    const stream1 = try manager.createStream();
    std.debug.print("Created stream {d} (state: idle)\n", .{stream1.id});

    const stream2 = try manager.createStream();
    std.debug.print("Created stream {d} (state: idle)\n", .{stream2.id});

    const stream3 = try manager.createStream();
    std.debug.print("Created stream {d} (state: idle)\n", .{stream3.id});

    try stream1.open();
    std.debug.print("Stream {d} opened (state: open)\n", .{stream1.id});

    stream1.sendEndStream();
    std.debug.print("Stream {d} sent END_STREAM (state: half_closed_local)\n", .{stream1.id});

    stream1.receiveEndStream();
    std.debug.print("Stream {d} received END_STREAM (state: closed)\n", .{stream1.id});

    std.debug.print("Active streams: {d}\n", .{manager.activeStreamCount()});

    const priority = httpx.StreamPriority{
        .dependency = 0,
        .weight = 32,
        .exclusive = false,
    };
    try stream2.open();
    stream2.priority = priority;
    std.debug.print("Stream {d} priority: weight={d}, dependency={d}\n", .{
        stream2.id,
        stream2.priority.weight,
        stream2.priority.dependency,
    });

    std.debug.print("\n", .{});
}

fn framingExample(allocator: std.mem.Allocator) !void {
    var stream_manager = httpx.StreamManager.init(allocator, true);
    defer stream_manager.deinit();

    const headers_result = try httpx.stream.buildHeadersFramePayload(
        &stream_manager,
        &[_]httpx.hpack.HeaderEntry{
            .{ .name = ":method", .value = "POST" },
            .{ .name = ":path", .value = "/api/data" },
            .{ .name = "content-type", .value = "application/json" },
        },
        null,
        allocator,
    );
    defer allocator.free(headers_result.payload);

    std.debug.print("HEADERS frame payload: {d} bytes\n", .{headers_result.payload.len});
    std.debug.print("HEADERS flags: 0x{x}\n", .{headers_result.flags});

    const rst_payload = httpx.stream.buildRstStreamPayload(.no_error);
    std.debug.print("RST_STREAM frame payload: {d} bytes\n", .{rst_payload.len});

    const window_update = httpx.stream.buildWindowUpdatePayload(32768);
    std.debug.print("WINDOW_UPDATE frame payload: {d} bytes (increment: 32768)\n", .{window_update.len});

    const goaway = try httpx.stream.buildGoawayPayload(0, .no_error, null, allocator);
    defer allocator.free(goaway);
    std.debug.print("GOAWAY frame payload: {d} bytes\n", .{goaway.len});

    const ping = httpx.stream.buildPingPayload(.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });
    std.debug.print("PING frame payload: {d} bytes\n", .{ping.len});

    const frame_header = httpx.Http2FrameHeader{
        .length = @intCast(headers_result.payload.len),
        .frame_type = .headers,
        .flags = headers_result.flags,
        .stream_id = 1,
    };
    const serialized = frame_header.serialize();
    std.debug.print("Frame header encoded: {d} bytes (type=HEADERS, stream=1)\n", .{serialized.len});

    std.debug.print("\nHTTP/2 frame types:\n", .{});
    const ft_info = @typeInfo(httpx.Http2FrameType).@"enum";
    if (comptime builtin.zig_version.minor >= 17) {
        inline for (ft_info.field_names, ft_info.field_values) |name, value| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ value, name });
        }
    } else {
        inline for (ft_info.fields) |field| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ field.value, field.name });
        }
    }

    std.debug.print("\n", .{});
}

fn flowControlExample(allocator: std.mem.Allocator) !void {
    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    const stream = try manager.createStream();
    try stream.open();

    std.debug.print("Initial send window: {d}\n", .{stream.send_window});
    std.debug.print("Initial recv window: {d}\n", .{stream.recv_window});
    std.debug.print("Connection send window: {d}\n", .{manager.connection_send_window});
    std.debug.print("Connection recv window: {d}\n", .{manager.connection_recv_window});

    const data_size: i32 = 16384;
    stream.send_window -= data_size;
    manager.connection_send_window -= data_size;
    std.debug.print("\nAfter sending {d} bytes:\n", .{data_size});
    std.debug.print("Stream send window: {d}\n", .{stream.send_window});
    std.debug.print("Connection send window: {d}\n", .{manager.connection_send_window});

    const increment: i32 = 32768;
    stream.send_window += increment;
    manager.connection_send_window += increment;
    std.debug.print("\nAfter WINDOW_UPDATE ({d}):\n", .{increment});
    std.debug.print("Stream send window: {d}\n", .{stream.send_window});
    std.debug.print("Connection send window: {d}\n", .{manager.connection_send_window});

    const wu_payload = httpx.stream.buildWindowUpdatePayload(65535);
    const parsed_increment = try httpx.stream.parseWindowUpdatePayload(&wu_payload);
    std.debug.print("\nParsed WINDOW_UPDATE increment: {d}\n", .{parsed_increment});

    std.debug.print("\nHTTP/2 error codes:\n", .{});
    const ec_info = @typeInfo(httpx.Http2ErrorCode).@"enum";
    if (comptime builtin.zig_version.minor >= 17) {
        inline for (ec_info.field_names, ec_info.field_values) |name, value| {
            std.debug.print("  0x{x}: {s}\n", .{ value, name });
        }
    } else {
        inline for (ec_info.fields) |field| {
            std.debug.print("  0x{x}: {s}\n", .{ field.value, field.name });
        }
    }

    std.debug.print("\n", .{});
}
