//! HTTP Protocol Implementation for httpx.zig
//!
//! Unified HTTP protocol support for multiple versions.
//!
//! This module focuses on protocol wire-format framing/types and helpers:
//!
//! - HTTP/1.x: request/response formatting utilities.
//! - HTTP/2: frame header + SETTINGS payload helpers, and basic frame IO.
//! - HTTP/3: QUIC varint + HTTP/3 frame header helpers.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

const types = @import("../core/types.zig");
const Headers = @import("../core/headers.zig").Headers;
const HeaderName = @import("../core/headers.zig").HeaderName;
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;
const Status = @import("../core/status.zig").Status;

/// HTTP protocol version negotiation result.
pub const NegotiatedProtocol = enum {
    http_1_0,
    http_1_1,
    http_2,
    http_3,

    pub fn toVersion(self: NegotiatedProtocol) types.Version {
        return switch (self) {
            .http_1_0 => .HTTP_1_0,
            .http_1_1 => .HTTP_1_1,
            .http_2 => .HTTP_2,
            .http_3 => .HTTP_3,
        };
    }
};

/// Standard Application-Layer Protocol Negotiation (ALPN) identifiers.
///
/// These strings obey the IANA registry for ALPN protocol IDs used in TLS handshakes:
/// - "http/1.1": HTTP/1.1
/// - "h2": HTTP/2 over TLS
/// - "h3": HTTP/3 over QUIC
pub const AlpnProtocol = struct {
    pub const HTTP_1_1 = "http/1.1";
    pub const HTTP_2 = "h2";
    pub const HTTP_3 = "h3";
};

/// HTTP/1.x connection handler for request/response exchange.
/// Manages the socket reader/writer, protocol versioning, and keep-alive state.
pub const Http1Connection = struct {
    allocator: Allocator,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    version: types.Version = .HTTP_1_1,
    keep_alive: bool = true,

    const Self = @This();

    /// Creates a new HTTP/1.x connection.
    pub fn init(allocator: Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Self {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
        };
    }

    /// Sends a request and awaits the response.
    pub fn sendRequest(self: *Self, req: *const Request) !Response {
        try self.writeRequest(req);
        return self.readResponse();
    }

    /// Serializes and writes the request to the underlying connection.
    fn writeRequest(self: *Self, req: *const Request) !void {
        const method_str = req.method.toString();
        const path = req.uri.path;
        const version_str = req.version.toString();

        try self.writer.print("{s} {s}", .{ method_str, path });
        if (req.uri.query) |q| {
            try self.writer.print("?{s}", .{q});
        }
        try self.writer.print(" {s}\r\n", .{version_str});

        for (req.headers.entries.items) |h| {
            try self.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try self.writer.writeAll("\r\n");

        if (req.body) |body| {
            try self.writer.writeAll(body);
        }
    }

    /// parse and construct the response object from the network stream.
    fn readResponse(self: *Self) !Response {
        var line_buf: [8192]u8 = undefined;

        const status_line = try self.readLine(&line_buf);
        const status_code = try parseStatusLine(status_line);

        var response = Response.init(self.allocator, status_code);
        errdefer response.deinit();

        while (true) {
            const header_line = try self.readLine(&line_buf);
            if (header_line.len == 0) break;

            if (mem.indexOf(u8, header_line, ":")) |sep| {
                const name = mem.trim(u8, header_line[0..sep], " \t");
                const value = mem.trim(u8, header_line[sep + 1 ..], " \t");
                try response.headers.append(name, value);
            }
        }

        self.keep_alive = response.headers.isKeepAlive(response.version);

        if (response.status.mayHaveBody()) {
            response.body = try self.readBody(&response.headers);
            response.body_owned = true;
        }

        return response;
    }

    /// Determines the body transfer method (Chunked, Content-Length, or Close) and reads the data.
    fn readBody(self: *Self, headers: *const Headers) ![]u8 {
        if (headers.isChunked()) {
            return self.readChunkedBody();
        }

        if (headers.getContentLength()) |length| {
            return self.readFixedBody(length);
        }

        return self.readUntilClose();
    }

    /// Reads a fixed number of bytes from the stream.
    fn readFixedBody(self: *Self, length: u64) ![]u8 {
        const body = try self.allocator.alloc(u8, @intCast(length));
        var read: usize = 0;
        while (read < length) {
            const n = try self.reader.read(body[read..]);
            if (n == 0) break;
            read += n;
        }
        return body;
    }

    /// Decodes a chunked transfer encoded body.
    fn readChunkedBody(self: *Self) ![]u8 {
        var result = std.ArrayListUnmanaged(u8){};
        var line_buf: [256]u8 = undefined;

        while (true) {
            const size_line = try self.readLine(&line_buf);
            const chunk_size = try std.fmt.parseInt(usize, size_line, 16);

            if (chunk_size == 0) break;

            const chunk = try self.allocator.alloc(u8, chunk_size);
            defer self.allocator.free(chunk);

            var read: usize = 0;
            while (read < chunk_size) {
                const n = try self.reader.read(chunk[read..]);
                if (n == 0) return error.UnexpectedEof;
                read += n;
            }

            try result.appendSlice(self.allocator, chunk);
            _ = try self.readLine(&line_buf);
        }

        _ = try self.readLine(&line_buf);
        return result.toOwnedSlice(self.allocator);
    }

    /// Reads all remaining data until the connection is closed by the peer.
    fn readUntilClose(self: *Self) ![]u8 {
        var result = std.ArrayListUnmanaged(u8){};
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = self.reader.read(&buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try result.appendSlice(self.allocator, buf[0..n]);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Reads a CRLF-terminated line from the stream.
    fn readLine(self: *Self, buf: []u8) ![]const u8 {
        var i: usize = 0;
        while (i < buf.len - 1) {
            const byte = self.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (byte == '\r') {
                const next = self.reader.readByte() catch '\n';
                if (next == '\n') break;
                buf[i] = byte;
                i += 1;
                buf[i] = next;
                i += 1;
            } else if (byte == '\n') {
                break;
            } else {
                buf[i] = byte;
                i += 1;
            }
        }
        return buf[0..i];
    }

    /// Indicates whether the persistent connection should remain open.
    pub fn shouldKeepAlive(self: *const Self) bool {
        return self.keep_alive;
    }
};

/// Parses the status line of an HTTP response (e.g., "HTTP/1.1 200 OK").
fn parseStatusLine(line: []const u8) !u16 {
    var parts = mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    const status_str = parts.next() orelse return error.InvalidResponse;
    return std.fmt.parseInt(u16, status_str, 10) catch error.InvalidResponse;
}

/// HTTP/2 frame types as defined in RFC 7540.
pub const Http2FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

/// Represents the 9-byte header standard for all HTTP/2 frames.
pub const Http2FrameHeader = struct {
    length: u24,
    frame_type: Http2FrameType,
    flags: u8,
    stream_id: u31,

    /// Encodes the frame header into wire format.
    pub fn serialize(self: Http2FrameHeader) [9]u8 {
        var buf: [9]u8 = undefined;
        buf[0] = @intCast((self.length >> 16) & 0xFF);
        buf[1] = @intCast((self.length >> 8) & 0xFF);
        buf[2] = @intCast(self.length & 0xFF);
        buf[3] = @intFromEnum(self.frame_type);
        buf[4] = self.flags;
        buf[5] = @intCast((self.stream_id >> 24) & 0x7F);
        buf[6] = @intCast((self.stream_id >> 16) & 0xFF);
        buf[7] = @intCast((self.stream_id >> 8) & 0xFF);
        buf[8] = @intCast(self.stream_id & 0xFF);
        return buf;
    }

    /// Decodes a frame header from wire format.
    pub fn parse(data: [9]u8) Http2FrameHeader {
        return .{
            .length = (@as(u24, data[0]) << 16) | (@as(u24, data[1]) << 8) | data[2],
            .frame_type = @enumFromInt(data[3]),
            .flags = data[4],
            .stream_id = (@as(u31, data[5] & 0x7F) << 24) | (@as(u31, data[6]) << 16) | (@as(u31, data[7]) << 8) | data[8],
        };
    }
};

/// The standard connection preface sent by the client to initiate HTTP/2.
pub const HTTP2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Configuration parameters for HTTP/2 connections.
pub const Http2Settings = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
};

/// Standard error codes for HTTP/2 stream and connection termination.
pub const Http2ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

/// Manages the state of an HTTP/2 connection, including HPack context and streams.
pub const Http2Connection = struct {
    allocator: Allocator,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    next_stream_id: u31 = 1,
    settings: Http2ConnectionSettings = .{},
    peer_settings: Http2ConnectionSettings = .{},

    const Self = @This();

    pub const Http2ConnectionSettings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = true,
        max_concurrent_streams: u32 = 100,
        initial_window_size: u32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = 8192,
    };

    pub const Frame = struct {
        header: Http2FrameHeader,
        payload: []u8,

        pub fn deinit(self: *Frame, allocator: Allocator) void {
            allocator.free(self.payload);
        }
    };

    /// Initializes a new HTTP/2 connection state.
    pub fn init(allocator: Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Self {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
        };
    }

    /// Initiates the HTTP/2 session by sending the preface and initial settings.
    pub fn handshake(self: *Self) !void {
        try self.writer.writeAll(HTTP2_PREFACE);
        try self.sendSettings();
    }

    /// Transmits the local settings to the peer.
    fn sendSettings(self: *Self) !void {
        var payload = std.ArrayListUnmanaged(u8){};
        defer payload.deinit(self.allocator);

        try encodeSettingsPayload(self.settings, self.allocator, &payload);
        const header = Http2FrameHeader{
            .length = @intCast(payload.items.len),
            .frame_type = .settings,
            .flags = 0,
            .stream_id = 0,
        };
        const serialized = header.serialize();
        try self.writer.writeAll(&serialized);
        if (payload.items.len > 0) {
            try self.writer.writeAll(payload.items);
        }
    }

    pub fn readFrame(self: *Self, allocator: Allocator, max_payload_size: usize) !Frame {
        var hdr_bytes: [9]u8 = undefined;
        try self.reader.readNoEof(&hdr_bytes);
        const header = Http2FrameHeader.parse(hdr_bytes);
        const len: usize = @intCast(header.length);
        if (len > max_payload_size) return error.FrameTooLarge;

        const payload = try allocator.alloc(u8, len);
        errdefer allocator.free(payload);
        if (len > 0) {
            try self.reader.readNoEof(payload);
        }
        return .{ .header = header, .payload = payload };
    }

    pub fn writeFrame(self: *Self, header: Http2FrameHeader, payload: []const u8) !void {
        const serialized = header.serialize();
        try self.writer.writeAll(&serialized);
        if (payload.len > 0) {
            try self.writer.writeAll(payload);
        }
    }
};

pub fn encodeSettingsPayload(settings: Http2Connection.Http2ConnectionSettings, allocator: Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    // Each setting is 6 bytes: 16-bit ID + 32-bit value.
    var buf: [6]u8 = undefined;

    // HEADER_TABLE_SIZE (0x1)
    writeU16BE(&buf, @intFromEnum(Http2Settings.header_table_size));
    writeU32BE(buf[2..6], settings.header_table_size);
    try out.appendSlice(allocator, &buf);

    // ENABLE_PUSH (0x2)
    writeU16BE(&buf, @intFromEnum(Http2Settings.enable_push));
    writeU32BE(buf[2..6], if (settings.enable_push) 1 else 0);
    try out.appendSlice(allocator, &buf);

    // MAX_CONCURRENT_STREAMS (0x3)
    writeU16BE(&buf, @intFromEnum(Http2Settings.max_concurrent_streams));
    writeU32BE(buf[2..6], settings.max_concurrent_streams);
    try out.appendSlice(allocator, &buf);

    // INITIAL_WINDOW_SIZE (0x4)
    writeU16BE(&buf, @intFromEnum(Http2Settings.initial_window_size));
    writeU32BE(buf[2..6], settings.initial_window_size);
    try out.appendSlice(allocator, &buf);

    // MAX_FRAME_SIZE (0x5)
    writeU16BE(&buf, @intFromEnum(Http2Settings.max_frame_size));
    writeU32BE(buf[2..6], settings.max_frame_size);
    try out.appendSlice(allocator, &buf);

    // MAX_HEADER_LIST_SIZE (0x6)
    writeU16BE(&buf, @intFromEnum(Http2Settings.max_header_list_size));
    writeU32BE(buf[2..6], settings.max_header_list_size);
    try out.appendSlice(allocator, &buf);
}

pub fn applySettingsPayload(settings: *Http2Connection.Http2ConnectionSettings, payload: []const u8) !void {
    if (payload.len % 6 != 0) return error.InvalidSettingsPayload;

    var i: usize = 0;
    while (i < payload.len) : (i += 6) {
        const id = readU16BE(payload[i..][0..2]);
        const value = readU32BE(payload[i..][2..6]);

        switch (@as(Http2Settings, @enumFromInt(id))) {
            .header_table_size => settings.header_table_size = value,
            .enable_push => settings.enable_push = (value != 0),
            .max_concurrent_streams => settings.max_concurrent_streams = value,
            .initial_window_size => settings.initial_window_size = value,
            .max_frame_size => settings.max_frame_size = value,
            .max_header_list_size => settings.max_header_list_size = value,
        }
    }
}

fn writeU16BE(buf: *[6]u8, v: u16) void {
    buf[0] = @intCast((v >> 8) & 0xFF);
    buf[1] = @intCast(v & 0xFF);
}

fn readU16BE(buf: []const u8) u16 {
    return (@as(u16, buf[0]) << 8) | buf[1];
}

fn writeU32BE(buf: []u8, v: u32) void {
    buf[0] = @intCast((v >> 24) & 0xFF);
    buf[1] = @intCast((v >> 16) & 0xFF);
    buf[2] = @intCast((v >> 8) & 0xFF);
    buf[3] = @intCast(v & 0xFF);
}

fn readU32BE(buf: []const u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | buf[3];
}

/// HTTP/3 frame types as defined in RFC 9114.
pub const Http3FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0D,
};

/// Configuration parameters for HTTP/3 connections.
pub const Http3Settings = struct {
    max_field_section_size: u64 = 0,
    qpack_max_table_capacity: u64 = 0,
    qpack_blocked_streams: u64 = 0,
};

/// Standard error codes for HTTP/3 stream and connection errors.
pub const Http3ErrorCode = enum(u64) {
    no_error = 0x100,
    general_protocol_error = 0x101,
    internal_error = 0x102,
    stream_creation_error = 0x103,
    closed_critical_stream = 0x104,
    frame_unexpected = 0x105,
    frame_error = 0x106,
    excessive_load = 0x107,
    id_error = 0x108,
    settings_error = 0x109,
    missing_settings = 0x10a,
    request_rejected = 0x10b,
    request_cancelled = 0x10c,
    request_incomplete = 0x10d,
    message_error = 0x10e,
    connect_error = 0x10f,
    version_fallback = 0x110,
};

/// Encodes an integer into the Variable-Length Integer format specified in RFC 9000.
pub fn encodeVarInt(value: u64, dest: []u8) !usize {
    if (value < 64) {
        if (dest.len < 1) return error.BufferTooSmall;
        dest[0] = @as(u8, @intCast(value));
        return 1;
    } else if (value < 16384) {
        if (dest.len < 2) return error.BufferTooSmall;
        dest[0] = @as(u8, @intCast((value >> 8) | 0x40));
        dest[1] = @as(u8, @intCast(value & 0xFF));
        return 2;
    } else if (value < 1073741824) {
        if (dest.len < 4) return error.BufferTooSmall;
        dest[0] = @as(u8, @intCast((value >> 24) | 0x80));
        dest[1] = @as(u8, @intCast((value >> 16) & 0xFF));
        dest[2] = @as(u8, @intCast((value >> 8) & 0xFF));
        dest[3] = @as(u8, @intCast(value & 0xFF));
        return 4;
    } else if (value < 4611686018427387904) {
        if (dest.len < 8) return error.BufferTooSmall;
        dest[0] = @as(u8, @intCast((value >> 56) | 0xC0));
        dest[1] = @as(u8, @intCast((value >> 48) & 0xFF));
        dest[2] = @as(u8, @intCast((value >> 40) & 0xFF));
        dest[3] = @as(u8, @intCast((value >> 32) & 0xFF));
        dest[4] = @as(u8, @intCast((value >> 24) & 0xFF));
        dest[5] = @as(u8, @intCast((value >> 16) & 0xFF));
        dest[6] = @as(u8, @intCast((value >> 8) & 0xFF));
        dest[7] = @as(u8, @intCast(value & 0xFF));
        return 8;
    }
    return error.ValueTooLarge;
}

/// Decodes an integer from the Variable-Length Integer format.
pub fn decodeVarInt(data: []const u8) !struct { value: u64, len: usize } {
    if (data.len == 0) return error.UnexpectedEof;
    const first = data[0];
    const prefix = first >> 6;
    const len: usize = @as(usize, 1) << @as(u3, @intCast(prefix));

    if (data.len < len) return error.UnexpectedEof;

    var value: u64 = @as(u64, first & 0x3F);
    var i: usize = 1;
    while (i < len) : (i += 1) {
        value = (value << 8) | data[i];
    }
    return .{ .value = value, .len = len };
}

/// HTTP/3 frame header (type + length), encoded as two QUIC varints.
pub const Http3FrameHeader = struct {
    frame_type: u64,
    length: u64,

    pub fn encode(self: Http3FrameHeader, out: []u8) !usize {
        var offset: usize = 0;
        offset += try encodeVarInt(self.frame_type, out[offset..]);
        offset += try encodeVarInt(self.length, out[offset..]);
        return offset;
    }

    pub fn decode(data: []const u8) !struct { header: Http3FrameHeader, len: usize } {
        const t = try decodeVarInt(data);
        const l = try decodeVarInt(data[t.len..]);
        return .{
            .header = .{ .frame_type = t.value, .length = l.value },
            .len = t.len + l.len,
        };
    }
};

/// Formats a request object into HTTP/1.x wire format.
pub fn formatRequest(req: *const Request, allocator: Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    const writer = buffer.writer(allocator);

    const method_str = req.method.toString();
    try writer.print("{s} {s}", .{ method_str, req.uri.path });
    if (req.uri.query) |q| {
        try writer.print("?{s}", .{q});
    }
    try writer.print(" {s}\r\n", .{req.version.toString()});

    for (req.headers.entries.items) |h| {
        try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.writeAll("\r\n");

    if (req.body) |body| {
        try writer.writeAll(body);
    }

    return buffer.toOwnedSlice(allocator);
}

/// Formats a response object into HTTP/1.x wire format.
pub fn formatResponse(resp: *const Response, allocator: Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    const writer = buffer.writer(allocator);

    try writer.print("{s} {d} {s}\r\n", .{
        resp.version.toString(),
        resp.status.code,
        resp.status.phrase,
    });

    for (resp.headers.entries.items) |h| {
        try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.writeAll("\r\n");

    if (resp.body) |body| {
        try writer.writeAll(body);
    }

    return buffer.toOwnedSlice(allocator);
}

/// Determines the highest supported HTTP version based on ALPN negotiation string.
pub fn negotiateVersion(alpn: ?[]const u8) NegotiatedProtocol {
    if (alpn) |protocol| {
        if (mem.eql(u8, protocol, AlpnProtocol.HTTP_3)) return .http_3;
        if (mem.eql(u8, protocol, AlpnProtocol.HTTP_2)) return .http_2;
        if (mem.eql(u8, protocol, AlpnProtocol.HTTP_1_1)) return .http_1_1;
    }
    return .http_1_1;
}

test "HTTP/1.1 request formatting" {
    const allocator = std.testing.allocator;
    var request = try Request.init(allocator, .GET, "https://example.com/api/users");
    defer request.deinit();

    const formatted = try formatRequest(&request, allocator);
    defer allocator.free(formatted);

    try std.testing.expect(mem.startsWith(u8, formatted, "GET /api/users HTTP/1.1\r\n"));
}

test "HTTP/1.1 response formatting" {
    const allocator = std.testing.allocator;
    var response = Response.init(allocator, 200);
    defer response.deinit();

    const formatted = try formatResponse(&response, allocator);
    defer allocator.free(formatted);

    try std.testing.expect(mem.startsWith(u8, formatted, "HTTP/1.1 200 OK\r\n"));
}

test "HTTP/2 frame header serialization" {
    const header = Http2FrameHeader{
        .length = 256,
        .frame_type = .data,
        .flags = 0x01,
        .stream_id = 1,
    };
    const serialized = header.serialize();
    const parsed = Http2FrameHeader.parse(serialized);

    try std.testing.expectEqual(header.length, parsed.length);
    try std.testing.expectEqual(header.frame_type, parsed.frame_type);
    try std.testing.expectEqual(header.stream_id, parsed.stream_id);
}

test "Protocol negotiation" {
    try std.testing.expectEqual(NegotiatedProtocol.http_2, negotiateVersion("h2"));
    try std.testing.expectEqual(NegotiatedProtocol.http_3, negotiateVersion("h3"));
    try std.testing.expectEqual(NegotiatedProtocol.http_1_1, negotiateVersion("http/1.1"));
    try std.testing.expectEqual(NegotiatedProtocol.http_1_1, negotiateVersion(null));
}

test "Status line parsing" {
    const status = try parseStatusLine("HTTP/1.1 200 OK");
    try std.testing.expectEqual(@as(u16, 200), status);

    const redirect = try parseStatusLine("HTTP/1.1 301 Moved Permanently");
    try std.testing.expectEqual(@as(u16, 301), redirect);
}

test "VarInt encoding" {
    var buf: [8]u8 = undefined;

    // 1 byte (0-63)
    var len = try encodeVarInt(25, &buf);
    try std.testing.expectEqual(@as(usize, 1), len);
    try std.testing.expectEqual(@as(u8, 25), buf[0]);
    var decoded = try decodeVarInt(buf[0..len]);
    try std.testing.expectEqual(@as(u64, 25), decoded.value);

    // 2 bytes (64-16383)
    len = try encodeVarInt(15293, &buf);
    try std.testing.expectEqual(@as(usize, 2), len);
    decoded = try decodeVarInt(buf[0..len]);
    try std.testing.expectEqual(@as(u64, 15293), decoded.value);

    // 4 bytes
    len = try encodeVarInt(494878333, &buf);
    try std.testing.expectEqual(@as(usize, 4), len);
    decoded = try decodeVarInt(buf[0..len]);
    try std.testing.expectEqual(@as(u64, 494878333), decoded.value);
}

test "HTTP/2 SETTINGS payload encode/decode" {
    const allocator = std.testing.allocator;

    const settings_in = Http2Connection.Http2ConnectionSettings{
        .header_table_size = 4096,
        .enable_push = false,
        .max_concurrent_streams = 123,
        .initial_window_size = 65535,
        .max_frame_size = 16384,
        .max_header_list_size = 9000,
    };

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try encodeSettingsPayload(settings_in, allocator, &payload);

    var settings_out = Http2Connection.Http2ConnectionSettings{};
    try applySettingsPayload(&settings_out, payload.items);

    try std.testing.expectEqual(settings_in.header_table_size, settings_out.header_table_size);
    try std.testing.expectEqual(settings_in.enable_push, settings_out.enable_push);
    try std.testing.expectEqual(settings_in.max_concurrent_streams, settings_out.max_concurrent_streams);
    try std.testing.expectEqual(settings_in.initial_window_size, settings_out.initial_window_size);
    try std.testing.expectEqual(settings_in.max_frame_size, settings_out.max_frame_size);
    try std.testing.expectEqual(settings_in.max_header_list_size, settings_out.max_header_list_size);
}

test "HTTP/3 frame header encode/decode" {
    var buf: [32]u8 = undefined;
    const hdr = Http3FrameHeader{ .frame_type = 0x01, .length = 1234 };
    const n = try hdr.encode(&buf);
    const decoded = try Http3FrameHeader.decode(buf[0..n]);
    try std.testing.expectEqual(hdr.frame_type, decoded.header.frame_type);
    try std.testing.expectEqual(hdr.length, decoded.header.length);
}
