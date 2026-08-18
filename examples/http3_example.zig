const std = @import("std");
const builtin = @import("builtin");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try qpackExample(allocator);

    try quicPacketExample(allocator);

    try quicFrameExample(allocator);

    try varintExample();

    try http3FrameExample(allocator);
}

fn qpackExample(allocator: std.mem.Allocator) !void {
    var ctx = httpx.QpackContext.init(allocator);
    defer ctx.deinit();

    std.debug.print("QPACK static table size: {d} entries\n", .{httpx.qpack.StaticTable.entries.len});
    std.debug.print("HPACK static table size: {d} entries\n", .{httpx.hpack.StaticTable.entries.len});

    const headers = [_]httpx.qpack.HeaderEntry{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/api/v3/resources" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "httpbun.com" },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    };

    const encoded = try httpx.qpack.encodeHeaders(&ctx, &headers, allocator);
    defer allocator.free(encoded);

    std.debug.print("Original headers: {d} fields\n", .{headers.len});
    std.debug.print("Encoded size: {d} bytes\n", .{encoded.len});

    var decode_ctx = httpx.QpackContext.init(allocator);
    defer decode_ctx.deinit();

    const decoded = try httpx.qpack.decodeHeaders(&decode_ctx, encoded, allocator);
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

    if (httpx.qpack.StaticTable.get(17)) |entry| {
        std.debug.print("Static table index 17: {s}={s}\n", .{ entry.name, entry.value });
    }
    if (httpx.qpack.StaticTable.findNameValue(":method", "POST")) |idx| {
        std.debug.print("Found :method=POST at index {d}\n", .{idx});
    }

    var encoder_stream = std.ArrayList(u8).empty;
    defer encoder_stream.deinit(allocator);

    try httpx.qpack.encodeSetCapacity(4096, &encoder_stream, allocator);
    std.debug.print("Encoder stream: Set Dynamic Table Capacity (4096)\n", .{});

    try httpx.qpack.encodeInsertNameRef(true, 17, "custom-value", &encoder_stream, allocator);
    std.debug.print("Encoder stream: Insert With Name Reference\n", .{});

    std.debug.print("Encoder stream total size: {d} bytes\n\n", .{encoder_stream.items.len});
}

fn quicPacketExample(allocator: std.mem.Allocator) !void {
    _ = allocator;

    const dcid = try httpx.quic.ConnectionId.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });
    const scid = try httpx.quic.ConnectionId.init(&[_]u8{ 0x11, 0x12, 0x13, 0x14 });

    std.debug.print("Destination CID: {d} bytes\n", .{dcid.len});
    std.debug.print("Source CID: {d} bytes\n", .{scid.len});

    const long_header = httpx.quic.LongHeader{
        .packet_type = .initial,
        .version = .v1,
        .dcid = dcid,
        .scid = scid,
    };

    var header_buf: [128]u8 = undefined;
    const header_len = try long_header.encode(&header_buf);

    std.debug.print("Long header encoded: {d} bytes\n", .{header_len});
    std.debug.print("  Packet type: Initial\n", .{});
    std.debug.print("  Version: QUIC v1 (0x00000001)\n", .{});

    const decoded = try httpx.quic.LongHeader.decode(header_buf[0..header_len]);
    std.debug.print("Decoded header:\n", .{});
    std.debug.print("  Packet type: {s}\n", .{@tagName(decoded.header.packet_type)});
    std.debug.print("  DCID length: {d}\n", .{decoded.header.dcid.len});
    std.debug.print("  SCID length: {d}\n", .{decoded.header.scid.len});

    const short_header = httpx.quic.ShortHeader{
        .dcid = dcid,
        .spin_bit = 0,
        .key_phase = 0,
    };

    var short_buf: [32]u8 = undefined;
    const short_len = try short_header.encode(&short_buf);
    std.debug.print("\nShort header encoded: {d} bytes\n", .{short_len});
    std.debug.print("  (Used for 1-RTT packets after handshake)\n\n", .{});
}

fn quicFrameExample(_: std.mem.Allocator) !void {
    const stream_frame = httpx.quic.StreamFrame{
        .stream_id = 4,
        .offset = 0,
        .data = "Hello, HTTP/3!",
        .fin = false,
    };

    var stream_buf: [128]u8 = undefined;
    const stream_len = try stream_frame.encode(&stream_buf);
    std.debug.print("STREAM frame: {d} bytes (stream_id={d})\n", .{ stream_len, stream_frame.stream_id });

    const decoded_stream = try httpx.quic.StreamFrame.decode(stream_buf[0..stream_len]);
    std.debug.print("  Decoded data: \"{s}\"\n", .{decoded_stream.frame.data});

    const crypto_frame = httpx.quic.CryptoFrame{
        .offset = 0,
        .data = &[_]u8{ 0x01, 0x00, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' },
    };

    var crypto_buf: [64]u8 = undefined;
    const crypto_len = try crypto_frame.encode(&crypto_buf);
    std.debug.print("CRYPTO frame: {d} bytes\n", .{crypto_len});

    const ack_frame = httpx.quic.AckFrame{
        .largest_acknowledged = 42,
        .ack_delay = 100,
        .first_ack_range = 10,
        .ack_ranges = &.{},
    };

    var ack_buf: [64]u8 = undefined;
    const ack_len = try ack_frame.encode(&ack_buf);
    std.debug.print("ACK frame: {d} bytes (largest_ack={d})\n", .{ ack_len, ack_frame.largest_acknowledged });

    const close_frame = httpx.quic.ConnectionCloseFrame{
        .error_code = @intFromEnum(httpx.quic.TransportError.no_error),
        .frame_type = null,
        .reason_phrase = "graceful shutdown",
    };

    var close_buf: [64]u8 = undefined;
    const close_len = try close_frame.encode(false, &close_buf);
    std.debug.print("CONNECTION_CLOSE frame: {d} bytes\n", .{close_len});

    std.debug.print("\nQUIC frame types:\n", .{});
    const qft_info = @typeInfo(httpx.quic.FrameType).@"enum";
    if (comptime builtin.zig_version.minor >= 17) {
        inline for (qft_info.field_names, qft_info.field_values) |name, value| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ value, name });
        }
    } else {
        inline for (qft_info.fields) |field| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ field.value, field.name });
        }
    }

    std.debug.print("\n", .{});
}

fn varintExample() !void {
    const test_values = [_]u64{ 0, 37, 15293, 494878333 };

    for (test_values) |value| {
        var buf: [8]u8 = undefined;
        const len = try httpx.quic.encodeVarInt(value, &buf);
        std.debug.print("Value {d}: {d} byte(s) encoded\n", .{ value, len });

        const decoded = try httpx.quic.decodeVarInt(&buf);
        std.debug.print("  Decoded: {d}\n", .{decoded.value});
    }

    std.debug.print("\nQUIC varint encoding ranges:\n", .{});
    std.debug.print("  1 byte:  0 - 63\n", .{});
    std.debug.print("  2 bytes: 64 - 16383\n", .{});
    std.debug.print("  4 bytes: 16384 - 1073741823\n", .{});
    std.debug.print("  8 bytes: 1073741824 - 4611686018427387903\n\n", .{});
}

fn http3FrameExample(allocator: std.mem.Allocator) !void {
    _ = allocator;

    std.debug.print("HTTP/3 unidirectional stream types:\n", .{});
    const h3st_info = @typeInfo(httpx.quic.Http3StreamType).@"enum";
    if (comptime builtin.zig_version.minor >= 17) {
        inline for (h3st_info.field_names, h3st_info.field_values) |name, value| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ value, name });
        }
    } else {
        inline for (h3st_info.fields) |field| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ field.value, field.name });
        }
    }

    std.debug.print("\nHTTP/3 frame types:\n", .{});
    std.debug.print("  0x00: DATA\n", .{});
    std.debug.print("  0x01: HEADERS\n", .{});
    std.debug.print("  0x03: CANCEL_PUSH\n", .{});
    std.debug.print("  0x04: SETTINGS\n", .{});
    std.debug.print("  0x05: PUSH_PROMISE\n", .{});
    std.debug.print("  0x07: GOAWAY\n", .{});
    std.debug.print("  0x0d: MAX_PUSH_ID\n", .{});

    std.debug.print("\nHTTP/3 settings identifiers:\n", .{});
    std.debug.print("  0x01: QPACK_MAX_TABLE_CAPACITY\n", .{});
    std.debug.print("  0x06: MAX_FIELD_SECTION_SIZE\n", .{});
    std.debug.print("  0x07: QPACK_BLOCKED_STREAMS\n", .{});

    std.debug.print("\nQUIC transport parameters:\n", .{});
    const tp_info = @typeInfo(httpx.quic.TransportParameter).@"enum";
    if (comptime builtin.zig_version.minor >= 17) {
        inline for (tp_info.field_names[0..10], tp_info.field_values[0..10]) |name, value| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ value, name });
        }
    } else {
        inline for (tp_info.fields[0..10]) |field| {
            std.debug.print("  0x{x:0>2}: {s}\n", .{ field.value, field.name });
        }
    }

    std.debug.print("\n", .{});
}
