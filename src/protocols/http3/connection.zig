// HTTP/3 connection (RFC 9114).
// Manages control stream lifecycle, SETTINGS exchange, and request/response
// on bidirectional streams. Transport (QUIC) integration via Conn interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("frame.zig");
const qpack_mod = @import("qpack.zig");
const varint = @import("../quic/varint.zig");

pub const CONTROL_STREAM_TYPE: u64 = 0x00;
pub const PUSH_STREAM_TYPE: u64 = 0x01;

pub const Error = error{
    ProtocolViolation,
    StreamClosed,
    InvalidSettings,
    OutOfMemory,
};

/// A single HTTP/3 message exchange on a bidirectional stream.
pub const RequestStream = struct {
    id: u64,
    allocator: Allocator,
    qpack: qpack_mod.Encoder,

    /// Builds HEADERS frame payload for a response.
    pub fn buildResponseHeaders(
        self: *RequestStream,
        status_code: u16,
        headers: []const qpack_mod.FieldLine,
    ) ![]u8 {
        var block = std.ArrayList(u8).empty;
        errdefer block.deinit(self.allocator);

        // Encoded Field Section Prefix: Required Insert Count = 0 and
        // Delta Base = 0. This response builder uses only static/literal
        // fields, so it must still emit the prefix required by RFC 9204
        // Section 4.5.
        try block.appendSlice(self.allocator, "\x00\x00");

        // Status pseudo-header
        var code_buf: [4]u8 = undefined;
        const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{status_code}) catch "500";
        try self.qpack.encodeField(&block, ":status", code_str);

        for (headers) |h| {
            if (std.mem.startsWith(u8, h.name, ":")) continue; // skip other pseudos
            try self.qpack.encodeField(&block, h.name, h.value);
        }

        // Wrap in HEADERS frame
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frame_mod.encodeFrameHeader(&fh, @intFromEnum(frame_mod.FrameType.headers), block.items.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, block.items);
        block.deinit(self.allocator);
        return out.toOwnedSlice(self.allocator);
    }

    /// Builds an HTTP/3 request HEADERS frame with the required pseudo
    /// headers and a zero dynamic-table QPACK prefix.
    pub fn buildRequestHeaders(
        self: *RequestStream,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        headers: []const qpack_mod.FieldLine,
    ) ![]u8 {
        var block = std.ArrayList(u8).empty;
        errdefer block.deinit(self.allocator);
        try block.appendSlice(self.allocator, "\x00\x00");
        try self.qpack.encodeField(&block, ":method", method);
        try self.qpack.encodeField(&block, ":scheme", scheme);
        try self.qpack.encodeField(&block, ":authority", authority);
        try self.qpack.encodeField(&block, ":path", path);
        for (headers) |h| {
            if (std.mem.startsWith(u8, h.name, ":")) return error.InvalidHeader;
            try self.qpack.encodeField(&block, h.name, h.value);
        }

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frame_mod.encodeFrameHeader(&fh, @intFromEnum(frame_mod.FrameType.headers), block.items.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, block.items);
        block.deinit(self.allocator);
        return out.toOwnedSlice(self.allocator);
    }

    /// Builds DATA frame payload.
    pub fn buildData(self: *RequestStream, body: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frame_mod.encodeFrameHeader(&fh, @intFromEnum(frame_mod.FrameType.data), body.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, body);
        return out.toOwnedSlice(self.allocator);
    }
};

/// Control stream builder - SETTINGS frame.
pub fn buildSettingsFrame(allocator: Allocator, entries: []const frame_mod.SettingEntry) ![]u8 {
    const payload = try frame_mod.buildSettingsPayload(allocator, entries);
    defer allocator.free(payload);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Stream type prefix (control = 0)
    var vb: [16]u8 = undefined;
    var n = try varint.encode(&vb, CONTROL_STREAM_TYPE);
    try out.appendSlice(allocator, vb[0..n]);

    // SETTINGS frame
    n = try frame_mod.encodeFrameHeader(&vb, @intFromEnum(frame_mod.FrameType.settings), payload.len);
    try out.appendSlice(allocator, vb[0..n]);
    try out.appendSlice(allocator, payload);
    return out.toOwnedSlice(allocator);
}

/// Builds a QPACK encoder stream type prefix.
pub fn buildQpackEncoderStreamPrefix(allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var vb: [16]u8 = undefined;
    const n = try varint.encode(&vb, frame_mod.UniStreamType.qpack_encoder);
    try out.appendSlice(allocator, vb[0..n]);
    return out.toOwnedSlice(allocator);
}

/// Builds a QPACK decoder stream type prefix.
pub fn buildQpackDecoderStreamPrefix(allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var vb: [16]u8 = undefined;
    const n = try varint.encode(&vb, frame_mod.UniStreamType.qpack_decoder);
    try out.appendSlice(allocator, vb[0..n]);
    return out.toOwnedSlice(allocator);
}

pub const PeerSettings = struct {
    max_field_section_size: u64 = 16384,
    qpack_max_table_capacity: u64 = 0,
    qpack_blocked_streams: u64 = 0,
};

/// HTTP/3 connection state machine. Manages control stream lifecycle,
/// SETTINGS exchange, QPACK integration, and stream multiplexing.
pub const Connection = struct {
    allocator: Allocator,
    role: Role,

    // Settings
    local_settings: PeerSettings = .{},
    peer_settings: PeerSettings = .{},
    settings_sent: bool = false,
    settings_received: bool = false,
    control_stream_started: bool = false,

    // QPACK state
    qenc: qpack_mod.Encoder,
    qdec: qpack_mod.Decoder,

    // Stream tracking
    next_bidi_id: u64,
    next_uni_id: u64,

    pub const Role = enum { client, server };

    pub fn init(allocator: Allocator, role: Role) Connection {
        const initiator_bit: u64 = if (role == .client) 0 else 1;
        return .{
            .allocator = allocator,
            .role = role,
            .qenc = qpack_mod.Encoder.init(allocator),
            .qdec = qpack_mod.Decoder.init(allocator),
            .next_bidi_id = initiator_bit,
            .next_uni_id = initiator_bit | 2,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.qenc.deinit();
        self.qdec.deinit();
    }

    /// Builds the control stream SETTINGS frame to send.
    pub fn buildControlStream(self: *Connection) ![]u8 {
        var entries: [4]frame_mod.SettingEntry = undefined;
        var count: usize = 0;

        entries[count] = .{ .id = 0x6, .value = self.local_settings.max_field_section_size };
        count += 1;

        if (self.local_settings.qpack_max_table_capacity > 0) {
            entries[count] = .{ .id = 0x1, .value = self.local_settings.qpack_max_table_capacity };
            count += 1;
        }

        if (self.local_settings.qpack_blocked_streams > 0) {
            entries[count] = .{ .id = 0x7, .value = self.local_settings.qpack_blocked_streams };
            count += 1;
        }

        const result = try buildSettingsFrame(self.allocator, entries[0..count]);
        self.settings_sent = true;
        return result;
    }

    /// Processes an incoming SETTINGS frame from the peer's control stream.
    pub fn processPeerSettings(self: *Connection, settings_entries: []const frame_mod.SettingEntry) !void {
        if (self.settings_received) return Error.InvalidSettings;
        var seen_qpack_capacity = false;
        var seen_max_field_section = false;
        var seen_blocked_streams = false;
        for (settings_entries) |entry| {
            switch (entry.id) {
                0x1 => {
                    if (seen_qpack_capacity) return Error.InvalidSettings;
                    seen_qpack_capacity = true;
                    self.peer_settings.qpack_max_table_capacity = entry.value;
                },
                0x2 => return Error.InvalidSettings, // ENABLE_PUSH is forbidden in HTTP/3.
                0x6 => {
                    if (seen_max_field_section) return Error.InvalidSettings;
                    seen_max_field_section = true;
                    self.peer_settings.max_field_section_size = entry.value;
                },
                0x7 => {
                    if (seen_blocked_streams) return Error.InvalidSettings;
                    seen_blocked_streams = true;
                    self.peer_settings.qpack_blocked_streams = entry.value;
                },
                else => {},
            }
        }
        self.qenc.setMaxTableCapacity(std.math.cast(usize, self.peer_settings.qpack_max_table_capacity) orelse return Error.InvalidSettings);
        self.settings_received = true;
    }

    /// Processes one frame received on the HTTP/3 control stream.
    ///
    /// Request-stream frames such as DATA and HEADERS are forbidden here.
    /// SETTINGS is accepted exactly once; integer-valued control frames are
    /// shape-validated and left for their feature-specific handlers.
    pub fn processControlFrame(self: *Connection, frame_type: u64, payload: []const u8) !void {
        self.control_stream_started = true;
        if (!self.settings_received and frame_type != 0x4) return Error.InvalidSettings;
        switch (frame_type) {
            0x0, 0x1, 0x5 => return Error.ProtocolViolation, // DATA, HEADERS, PUSH_PROMISE
            0x4 => {
                const entries = frame_mod.parseSettingsPayload(payload, self.allocator) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => return Error.InvalidSettings,
                };
                defer self.allocator.free(entries);
                try self.processPeerSettings(entries);
            },
            0x3, 0x7, 0xD => {
                const entries = frame_mod.validateFramePayload(self.allocator, frame_type, payload) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => return Error.ProtocolViolation,
                };
                self.allocator.free(entries);
            },
            else => {}, // Unknown control frames are ignored per RFC 9114.
        }
    }

    /// Allocates the next bidirectional stream ID.
    pub fn nextBidiStreamId(self: *Connection) u64 {
        const id = self.next_bidi_id;
        self.next_bidi_id += 4;
        return id;
    }

    /// Allocates the next unidirectional stream ID.
    pub fn nextUniStreamId(self: *Connection) u64 {
        const id = self.next_uni_id;
        self.next_uni_id += 4;
        return id;
    }
};

// Tests

test "settings frame structure" {
    const a = std.testing.allocator;
    const entries = [_]frame_mod.SettingEntry{
        .{ .id = 0x6, .value = 16384 }, // max_field_section_size
    };
    const f = try buildSettingsFrame(a, &entries);
    defer a.free(f);

    // First byte: control stream type varint
    try std.testing.expectEqual(@as(u8, 0x00), f[0]);
    // Second byte: settings frame type
    try std.testing.expectEqual(@as(u8, 0x04), f[1]);
}

test "connection deinit releases qpack dynamic tables" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .client);
    c.qenc.setMaxTableCapacity(256);
    c.qdec.setMaxTableCapacity(256);
    _ = try c.qenc.dyn.?.insert(a, "x-test", "encoder");
    _ = try c.qdec.dyn.?.insert(a, "x-test", "decoder");
    c.deinit();
}

test "qpack capacity changes release the previous table" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .client);
    c.qenc.setMaxTableCapacity(256);
    c.qdec.setMaxTableCapacity(256);
    _ = try c.qenc.dyn.?.insert(a, "x-old", "encoder");
    _ = try c.qdec.dyn.?.insert(a, "x-old", "decoder");
    c.qenc.setMaxTableCapacity(512);
    c.qdec.setMaxTableCapacity(512);
    c.qenc.setMaxTableCapacity(0);
    c.qdec.setMaxTableCapacity(0);
    c.deinit();
}

test "request stream builds valid HEADERS + DATA" {
    const a = std.testing.allocator;
    var rs = RequestStream{
        .id = 4,
        .allocator = a,
        .qpack = qpack_mod.Encoder.init(a),
    };

    const hdrs = [_]qpack_mod.FieldLine{
        .{ .name = "content-type", .value = "text/plain" },
    };
    const head_frame = try rs.buildResponseHeaders(200, &hdrs);
    defer a.free(head_frame);

    // Frame type should be HEADERS (0x01)
    try std.testing.expectEqual(@as(u8, 0x01), head_frame[0]);
    var frame_offset: usize = 0;
    const header_frame = try frame_mod.parseFrame(head_frame, &frame_offset);
    var decoder = qpack_mod.Decoder.init(a);
    const decoded = try decoder.decodeSectionWithPrefix(header_frame.payload);
    defer decoder.freeFields(decoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings(":status", decoded[0].name);
    try std.testing.expectEqualStrings("200", decoded[0].value);

    const data_frame = try rs.buildData("hello");
    defer a.free(data_frame);
    try std.testing.expectEqual(@as(u8, 0x00), data_frame[0]); // DATA
    try std.testing.expectEqual(@as(u8, 'h'), data_frame[data_frame.len - 5]);
}

test "request stream builds decodable request headers" {
    const a = std.testing.allocator;
    var rs = RequestStream{ .id = 0, .allocator = a, .qpack = qpack_mod.Encoder.init(a) };
    const headers = [_]qpack_mod.FieldLine{.{ .name = "user-agent", .value = "httpx" }};
    const encoded = try rs.buildRequestHeaders("GET", "https", "example.test", "/", &headers);
    defer a.free(encoded);

    var offset: usize = 0;
    const frame = try frame_mod.parseFrame(encoded, &offset);
    var dec = qpack_mod.Decoder.init(a);
    const fields = try dec.decodeSectionWithPrefix(frame.payload);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
    try std.testing.expectEqualStrings("GET", fields[0].value);
    try std.testing.expectEqualStrings(":path", fields[3].name);
}

test "connection builds and processes settings" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .client);
    defer conn.deinit();

    // Build control stream
    const ctrl = try conn.buildControlStream();
    defer a.free(ctrl);

    // First byte should be control stream type 0x00
    try std.testing.expectEqual(@as(u8, 0x00), ctrl[0]);

    // Process peer settings
    const entries = [_]frame_mod.SettingEntry{
        .{ .id = 0x6, .value = 8192 },
        .{ .id = 0x7, .value = 100 },
    };
    try conn.processPeerSettings(&entries);
    try std.testing.expectEqual(@as(u64, 8192), conn.peer_settings.max_field_section_size);
    try std.testing.expectEqual(@as(u64, 100), conn.peer_settings.qpack_blocked_streams);
}

test "http3 rejects duplicate and forbidden settings" {
    const a = std.testing.allocator;
    var duplicate = Connection.init(a, .client);
    defer duplicate.deinit();
    const dup = [_]frame_mod.SettingEntry{
        .{ .id = 0x6, .value = 8192 },
        .{ .id = 0x6, .value = 4096 },
    };
    try std.testing.expectError(Error.InvalidSettings, duplicate.processPeerSettings(&dup));

    var forbidden = Connection.init(a, .client);
    defer forbidden.deinit();
    const enable_push = [_]frame_mod.SettingEntry{.{ .id = 0x2, .value = 0 }};
    try std.testing.expectError(Error.InvalidSettings, forbidden.processPeerSettings(&enable_push));
}

test "http3 control stream rejects request frames and accepts settings" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .server);
    defer c.deinit();
    try std.testing.expectError(Error.InvalidSettings, c.processControlFrame(0x0, ""));

    const entries = [_]frame_mod.SettingEntry{.{ .id = 0x6, .value = 4096 }};
    const encoded = try frame_mod.buildSettingsPayload(a, &entries);
    defer a.free(encoded);
    try c.processControlFrame(0x4, encoded);
    try std.testing.expect(c.settings_received);
    try std.testing.expectError(Error.InvalidSettings, c.processControlFrame(0x4, encoded));
}

test "connection allocates stream IDs" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .client);
    defer conn.deinit();

    const s0 = conn.nextBidiStreamId();
    const s1 = conn.nextBidiStreamId();
    const s2 = conn.nextUniStreamId();
    try std.testing.expectEqual(@as(u64, 0), s0);
    try std.testing.expectEqual(@as(u64, 4), s1);
    try std.testing.expectEqual(@as(u64, 2), s2);
    try std.testing.expect((s0 & 3) == 0 and (s2 & 3) == 2);

    var server = Connection.init(a, .server);
    defer server.deinit();
    try std.testing.expectEqual(@as(u64, 1), server.nextBidiStreamId());
    try std.testing.expectEqual(@as(u64, 3), server.nextUniStreamId());
}
