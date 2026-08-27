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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
