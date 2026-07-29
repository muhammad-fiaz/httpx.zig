//! HTTP/3 High-Level Client Runtime Example for httpx.zig
//!
//! This example demonstrates an end-to-end local HTTP/3 request/response flow
//! using the high-level client API (`ClientConfig.http3_enabled = true`) over
//! UDP with QUIC/HTTP3/QPACK protocol primitives.

const std = @import("std");
const httpx = @import("httpx");

const H3_SETTING_QPACK_MAX_TABLE_CAPACITY: u64 = 0x01;
const H3_SETTING_MAX_FIELD_SECTION_SIZE: u64 = 0x06;
const H3_SETTING_QPACK_BLOCKED_STREAMS: u64 = 0x07;
const H3_SETTING_ENABLE_CONNECT_PROTOCOL: u64 = 0x08;

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server_socket = try httpx.UdpSocket.create();
    try server_socket.setReuseAddr(true);
    const listen_addr = try httpx.Address.parseIp("127.0.0.1", 0);
    try server_socket.bind(listen_addr);

    const local_addr = try server_socket.getLocalAddress();
    const port = local_addr.getPort();

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_socket});
    defer server_thread.join();
    defer server_socket.close();

    var client = httpx.Client.initWithConfig(allocator, .{
        .http3_enabled = true,
        .http2_enabled = false,
        .keep_alive = false,
        .http3_settings = .{
            .qpack_max_table_capacity = 4096,
            .qpack_blocked_streams = 16,
            .max_field_section_size = 8192,
        },
    });
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/runtime", .{port});
    defer allocator.free(url);

    var response = try client.get(url, .{ .timeout_ms = 10_000 });
    defer response.deinit();

    std.debug.print("\n=== HTTP/3 Client Runtime Example ===\n", .{});
    std.debug.print("Response version: {s}\n", .{response.version.toString()});
    std.debug.print("Status: {d}\n", .{response.status.code});
    std.debug.print("Body: {s}\n", .{response.text() orelse ""});
}

fn serverThreadMain(server_socket: *httpx.UdpSocket) void {
    runServer(server_socket) catch |err| {
        std.debug.print("local h3 server error: {s}\n", .{@errorName(err)});
    };
}

fn runServer(server_socket: *httpx.UdpSocket) !void {
    const allocator = std.heap.page_allocator;

    var recv_buf: [64 * 1024]u8 = undefined;

    var peer_addr: ?httpx.Address = null;
    var client_cid: ?httpx.quic.ConnectionId = null;

    var control_stream_payload = std.ArrayList(u8).empty;
    defer control_stream_payload.deinit(allocator);

    var request_stream_payload = std.ArrayList(u8).empty;
    defer request_stream_payload.deinit(allocator);

    var request_done = false;
    var request_stream_id: u64 = 0;

    while (!request_done) {
        const incoming = try server_socket.recvFrom(&recv_buf);
        peer_addr = incoming.addr;

        const decoded = try decodeIncomingDatagram(recv_buf[0..incoming.n]);
        if (decoded.client_scid) |cid| {
            client_cid = cid;
        }

        if (decoded.stream_id == 2) {
            try control_stream_payload.appendSlice(allocator, decoded.data);
        } else if ((decoded.stream_id & 0x03) == 0) {
            request_stream_id = decoded.stream_id;
            try request_stream_payload.appendSlice(allocator, decoded.data);
            if (decoded.fin) {
                request_done = true;
            }
        }
    }

    const dst_addr = peer_addr orelse return error.ProtocolError;
    const dst_cid = client_cid orelse return error.ProtocolError;

    try validateControlStream(control_stream_payload.items);
    try validateRequestStream(request_stream_payload.items, allocator);

    const response_body = "hello from local h3 server";
    var len_buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{response_body.len});

    var qpack_ctx = httpx.QpackContext.init(allocator);
    defer qpack_ctx.deinit();

    const response_headers = [_]httpx.qpack.HeaderEntry{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-length", .value = len_str },
    };

    const encoded_response_headers = try httpx.qpack.encodeHeaders(&qpack_ctx, &response_headers, allocator);
    defer allocator.free(encoded_response_headers);

    var response_stream_data = std.ArrayList(u8).empty;
    defer response_stream_data.deinit(allocator);
    try appendHttp3Frame(&response_stream_data, allocator, .headers, encoded_response_headers);
    try appendHttp3Frame(&response_stream_data, allocator, .data, response_body);

    var settings_payload = std.ArrayList(u8).empty;
    defer settings_payload.deinit(allocator);
    try encodeHttp3SettingsPayload(.{}, allocator, &settings_payload);

    var server_control_data = std.ArrayList(u8).empty;
    defer server_control_data.deinit(allocator);
    try appendVarInt(&server_control_data, allocator, @intFromEnum(httpx.quic.Http3StreamType.control));
    try appendHttp3Frame(&server_control_data, allocator, .settings, settings_payload.items);

    const server_cid = try httpx.quic.ConnectionId.init(&[_]u8{ 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8 });

    const control_packet = try buildServerDatagram(
        allocator,
        dst_cid,
        server_cid,
        1,
        3,
        0,
        false,
        server_control_data.items,
    );
    defer allocator.free(control_packet);

    const response_packet = try buildServerDatagram(
        allocator,
        dst_cid,
        server_cid,
        2,
        request_stream_id,
        0,
        true,
        response_stream_data.items,
    );
    defer allocator.free(response_packet);

    _ = try server_socket.sendTo(dst_addr, control_packet);
    _ = try server_socket.sendTo(dst_addr, response_packet);

    sleepMs(25);
}

const DecodedIncoming = struct {
    stream_id: u64,
    fin: bool,
    data: []const u8,
    client_scid: ?httpx.quic.ConnectionId = null,
};

fn decodeIncomingDatagram(datagram: []const u8) !DecodedIncoming {
    if (datagram.len == 0) return error.ProtocolError;

    var offset: usize = 0;
    var client_scid: ?httpx.quic.ConnectionId = null;

    if ((datagram[0] & 0x80) != 0) {
        const long_header = try httpx.quic.LongHeader.decode(datagram);
        offset = long_header.len;
        if (long_header.header.scid.len > 0) {
            client_scid = long_header.header.scid;
        }
    } else {
        const short_header = try httpx.quic.ShortHeader.decode(datagram, 8);
        offset = short_header.len;
    }

    const packet_number = try httpx.quic.decodeVarInt(datagram[offset..]);
    _ = packet_number.value;
    offset += packet_number.len;

    if (offset >= datagram.len) return error.ProtocolError;
    if (!httpx.quic.FrameType.isStream(@as(u64, datagram[offset]))) return error.ProtocolError;

    const stream = try httpx.quic.StreamFrame.decode(datagram[offset..]);
    if (stream.len != datagram[offset..].len) return error.ProtocolError;

    return .{
        .stream_id = stream.frame.stream_id,
        .fin = stream.frame.fin,
        .data = stream.frame.data,
        .client_scid = client_scid,
    };
}

fn buildServerDatagram(
    allocator: std.mem.Allocator,
    dcid: httpx.quic.ConnectionId,
    scid: httpx.quic.ConnectionId,
    packet_number: u64,
    stream_id: u64,
    stream_offset: u64,
    fin: bool,
    payload: []const u8,
) ![]u8 {
    const frame_storage = try allocator.alloc(u8, payload.len + 64);
    defer allocator.free(frame_storage);

    const stream_frame = httpx.quic.StreamFrame{
        .stream_id = stream_id,
        .offset = stream_offset,
        .length = @intCast(payload.len),
        .fin = fin,
        .data = payload,
    };
    const frame_len = try stream_frame.encode(frame_storage);

    var packet = std.ArrayList(u8).empty;
    errdefer packet.deinit(allocator);

    var header_buf: [128]u8 = undefined;
    const header_len = try (httpx.quic.LongHeader{
        .packet_type = .initial,
        .version = .v1,
        .dcid = dcid,
        .scid = scid,
    }).encode(&header_buf);
    try packet.appendSlice(allocator, header_buf[0..header_len]);

    var packet_number_buf: [8]u8 = undefined;
    const packet_number_len = try httpx.quic.encodeVarInt(packet_number, &packet_number_buf);
    try packet.appendSlice(allocator, packet_number_buf[0..packet_number_len]);

    try packet.appendSlice(allocator, frame_storage[0..frame_len]);
    return packet.toOwnedSlice(allocator);
}

fn appendVarInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var tmp: [8]u8 = undefined;
    const n = try httpx.http.encodeVarInt(value, &tmp);
    try out.appendSlice(allocator, tmp[0..n]);
}

fn appendHttp3Frame(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    frame_type: httpx.http.Http3FrameType,
    payload: []const u8,
) !void {
    var frame_header_buf: [32]u8 = undefined;
    const frame_header_len = try (httpx.http.Http3FrameHeader{
        .frame_type = @intFromEnum(frame_type),
        .length = @intCast(payload.len),
    }).encode(&frame_header_buf);

    try out.appendSlice(allocator, frame_header_buf[0..frame_header_len]);
    try out.appendSlice(allocator, payload);
}

fn encodeHttp3SettingsPayload(
    settings: httpx.Http3Settings,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
) !void {
    try appendVarInt(out, allocator, H3_SETTING_QPACK_MAX_TABLE_CAPACITY);
    try appendVarInt(out, allocator, settings.qpack_max_table_capacity);

    try appendVarInt(out, allocator, H3_SETTING_MAX_FIELD_SECTION_SIZE);
    try appendVarInt(out, allocator, settings.max_field_section_size);

    try appendVarInt(out, allocator, H3_SETTING_QPACK_BLOCKED_STREAMS);
    try appendVarInt(out, allocator, settings.qpack_blocked_streams);

    if (settings.enable_connect_protocol) {
        try appendVarInt(out, allocator, H3_SETTING_ENABLE_CONNECT_PROTOCOL);
        try appendVarInt(out, allocator, 1);
    }
}

fn validateControlStream(control_stream_data: []const u8) !void {
    if (control_stream_data.len == 0) return error.ProtocolError;

    var offset: usize = 0;
    const stream_type = try httpx.http.decodeVarInt(control_stream_data[offset..]);
    offset += stream_type.len;

    if (stream_type.value != @intFromEnum(httpx.quic.Http3StreamType.control)) {
        return error.ProtocolError;
    }

    var saw_settings = false;
    while (offset < control_stream_data.len) {
        const header = try httpx.http.Http3FrameHeader.decode(control_stream_data[offset..]);
        offset += header.len;

        const frame_len: usize = @intCast(header.header.length);
        if (control_stream_data.len < offset + frame_len) return error.ProtocolError;
        offset += frame_len;

        if (header.header.frame_type == @intFromEnum(httpx.http.Http3FrameType.settings)) {
            saw_settings = true;
        }
    }

    if (!saw_settings) return error.ProtocolError;
}

fn validateRequestStream(request_stream_data: []const u8, allocator: std.mem.Allocator) !void {
    var offset: usize = 0;
    var saw_headers = false;

    var qpack_ctx = httpx.QpackContext.init(allocator);
    defer qpack_ctx.deinit();

    while (offset < request_stream_data.len) {
        const header = try httpx.http.Http3FrameHeader.decode(request_stream_data[offset..]);
        offset += header.len;

        const frame_len: usize = @intCast(header.header.length);
        if (request_stream_data.len < offset + frame_len) return error.ProtocolError;

        const frame_payload = request_stream_data[offset .. offset + frame_len];
        offset += frame_len;

        if (header.header.frame_type == @intFromEnum(httpx.http.Http3FrameType.headers)) {
            const decoded = try httpx.qpack.decodeHeaders(&qpack_ctx, frame_payload, allocator);
            defer {
                for (decoded) |h| {
                    allocator.free(h.name);
                    allocator.free(h.value);
                }
                allocator.free(decoded);
            }
            saw_headers = decoded.len > 0;
        }
    }

    if (!saw_headers) return error.ProtocolError;
}
