//! HTTP/3 frame types and encoding (RFC 9114 section 7.2).
//!
//! References:
//!   - RFC 9114 Section 7.2 — Frame Types (DATA, HEADERS, RESERVED, SETTINGS,
//!     PUSH_PROMISE, GOAWAY, MAX_PUSH_ID)
//!   - RFC 9114 Section 8.1 — HTTP/3 Error Codes

const std = @import("std");
const varint = @import("../quic/varint.zig");
const Allocator = std.mem.Allocator;

/// HTTP/3 error codes (RFC 9114 section 8.1).
pub const H3Error = enum(u64) {
    h3_no_error = 0x0100,
    h3_general_protocol_error = 0x0101,
    h3_internal_error = 0x0102,
    h3_stream_creation_error = 0x0103,
    h3_closed_critical_stream = 0x0104,
    h3_frame_unexpected = 0x0105,
    h3_frame_error = 0x0106,
    h3_excessive_load = 0x0107,
    h3_id_error = 0x0108,
    h3_settings_error = 0x0109,
    h3_missing_settings = 0x010a,
    h3_request_rejected = 0x010b,
    h3_request_cancelled = 0x010c,
    h3_request_incomplete = 0x010d,
    h3_message_error = 0x010e,
    h3_connect_error = 0x010f,
    h3_version_fallback = 0x0110,
    qpack_general_error = 0x0200,
    qpack_encoder_stream_error = 0x0201,
    qpack_decoder_stream_error = 0x0202,
};

/// Stream type identifiers for unidirectional streams.
pub const UniStreamType = struct {
    pub const control: u64 = 0x00;
    pub const push: u64 = 0x01;
    pub const qpack_encoder: u64 = 0x02;
    pub const qpack_decoder: u64 = 0x03;
};

pub const FrameType = enum(u64) {
    data = 0x0,
    headers = 0x1,
    cancel_push = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    goaway = 0x7,
    max_push_id = 0xD,
    _,

    pub fn fromInt(v: u64) FrameType {
        return @enumFromInt(v);
    }
};

pub const Error = error{ Truncated, InvalidFrame, OutOfMemory, BufferTooSmall, TooLarge };

pub const FrameHeader = struct {
    frame_type: u64,
    length: u64,
};

pub const ParsedFrame = struct {
    frame_type: u64,
    payload: []const u8,
};

/// Validates the payload shape of an HTTP/3 frame.
///
/// Unknown frame types are intentionally accepted and ignored by higher
/// layers, but all defined frame types must have the wire shape required by
/// RFC 9114 Section 7.2. The returned SETTINGS entries are owned by the
/// caller; non-SETTINGS frames return an empty owned slice.
pub fn validateFramePayload(
    allocator: Allocator,
    frame_type: u64,
    payload: []const u8,
) Error![]SettingEntry {
    switch (frame_type) {
        0x0, 0x1 => return allocator.alloc(SettingEntry, 0), // DATA and HEADERS
        0x3, 0x5, 0x7, 0xD => {
            var offset: usize = 0;
            _ = varint.decode(payload, &offset) catch |e| switch (e) {
                error.Truncated => return Error.Truncated,
                else => return Error.InvalidFrame,
            };
            if (offset != payload.len) return Error.InvalidFrame;
            return allocator.alloc(SettingEntry, 0);
        },
        0x4 => return parseSettingsPayload(payload, allocator),
        else => return allocator.alloc(SettingEntry, 0),
    }
}

/// Parses an H3 frame header at data[offset..]. Advances offset.
pub fn parseFrameHeader(data: []const u8, offset: *usize) Error!FrameHeader {
    const ft = varint.decode(data, offset) catch |e| switch (e) {
        error.Truncated => return Error.Truncated,
        else => return Error.InvalidFrame,
    };
    const len = varint.decode(data, offset) catch |e| switch (e) {
        error.Truncated => return Error.Truncated,
        else => return Error.InvalidFrame,
    };
    return .{ .frame_type = ft, .length = len };
}

/// Parses one complete HTTP/3 frame and advances `offset` past its payload.
/// The returned payload aliases `data` and is valid for the lifetime of that
/// input buffer.
pub fn parseFrame(data: []const u8, offset: *usize) Error!ParsedFrame {
    const header = try parseFrameHeader(data, offset);
    const n = std.math.cast(usize, header.length) orelse return Error.TooLarge;
    if (offset.* > data.len or n > data.len - offset.*) return Error.Truncated;
    const payload = data[offset.*..][0..n];
    offset.* += n;
    return .{ .frame_type = header.frame_type, .payload = payload };
}

/// Encodes a frame header into buf. Returns bytes written.
pub fn encodeFrameHeader(buf: []u8, frame_type: u64, length: u64) Error!usize {
    const n1 = varint.encode(buf, frame_type) catch return Error.BufferTooSmall;
    const n2 = varint.encode(buf[n1..], length) catch return Error.BufferTooSmall;
    return n1 + n2;
}

/// SETTINGS parameter IDs (RFC 9114 section 7.2.4).
pub const SettingsId = enum(u64) {
    qpack_max_table_capacity = 0x1,
    max_field_section_size = 0x6,
    qpack_blocked_streams = 0x7,
    _,
};

pub const SettingEntry = struct { id: u64, value: u64 };

/// Decodes an HTTP/3 SETTINGS payload.
///
/// SETTINGS identifiers must be unique. The identifiers reserved by HTTP/2
/// (0x2, 0x3, 0x4, and 0x5) are connection errors when they appear in HTTP/3;
/// unknown identifiers are retained for forward compatibility as required by
/// RFC 9114 Section 7.2.8.
pub fn parseSettingsPayload(data: []const u8, allocator: Allocator) Error![]SettingEntry {
    var out = std.ArrayList(SettingEntry).empty;
    errdefer out.deinit(allocator);

    var offset: usize = 0;
    while (offset < data.len) {
        const id = varint.decode(data, &offset) catch |e| switch (e) {
            error.Truncated => return Error.Truncated,
            else => return Error.InvalidFrame,
        };
        const value = varint.decode(data, &offset) catch |e| switch (e) {
            error.Truncated => return Error.Truncated,
            else => return Error.InvalidFrame,
        };

        switch (id) {
            0x2, 0x3, 0x4, 0x5 => return Error.InvalidFrame,
            else => {},
        }
        for (out.items) |previous| {
            if (previous.id == id) return Error.InvalidFrame;
        }
        try out.append(allocator, .{ .id = id, .value = value });
    }
    return out.toOwnedSlice(allocator);
}

/// Serializes SETTINGS entries into payload bytes.
pub fn buildSettingsPayload(allocator: Allocator, entries: []const SettingEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (entries, 0..) |e, i| {
        switch (e.id) {
            0x2, 0x3, 0x4, 0x5 => return Error.InvalidFrame,
            else => {},
        }
        for (entries[0..i]) |previous| {
            if (previous.id == e.id) return Error.InvalidFrame;
        }
        var buf: [8]u8 = undefined;
        var n: usize = undefined;
        n = try varint.encode(&buf, e.id);
        try out.appendSlice(allocator, buf[0..n]);
        n = try varint.encode(&buf, e.value);
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

test "frame header roundtrip" {
    var buf: [16]u8 = undefined;
    const n = try encodeFrameHeader(&buf, 0x1, 300);
    var offset: usize = 0;
    const fh = try parseFrameHeader(buf[0..n], &offset);
    try std.testing.expectEqual(@as(u64, 0x1), fh.frame_type);
    try std.testing.expectEqual(@as(u64, 300), fh.length);
    try std.testing.expectEqual(n, offset);
}

test "complete frame parser rejects truncated payload" {
    var buf: [16]u8 = undefined;
    const n = try encodeFrameHeader(&buf, 0x0, 5);
    var offset: usize = 0;
    try std.testing.expectError(Error.Truncated, parseFrame(buf[0..n], &offset));

    buf[n] = 1;
    buf[n + 1] = 2;
    var offset2: usize = 0;
    try std.testing.expectError(Error.Truncated, parseFrame(buf[0 .. n + 2], &offset2));
}

test "settings payload roundtrip" {
    const a = std.testing.allocator;
    const entries = [_]SettingEntry{
        .{ .id = 0x1, .value = 4096 },
        .{ .id = 0x6, .value = 16384 },
    };
    const payload = try buildSettingsPayload(a, &entries);
    defer a.free(payload);
    // Each entry is 1-byte id + up to 2-byte value
    try std.testing.expect(payload.len >= 3);
}

test "settings payload rejects duplicate and HTTP/2-only identifiers" {
    const a = std.testing.allocator;
    var duplicate: [16]u8 = undefined;
    var n = try varint.encode(&duplicate, 0x6);
    n += try varint.encode(duplicate[n..], 1);
    n += try varint.encode(duplicate[n..], 0x6);
    n += try varint.encode(duplicate[n..], 2);
    try std.testing.expectError(Error.InvalidFrame, parseSettingsPayload(duplicate[0..n], a));

    var reserved: [8]u8 = undefined;
    n = try varint.encode(&reserved, 0x4);
    n += try varint.encode(reserved[n..], 0);
    try std.testing.expectError(Error.InvalidFrame, parseSettingsPayload(reserved[0..n], a));
}

test "settings builder rejects duplicate and reserved identifiers" {
    const a = std.testing.allocator;
    const duplicate = [_]SettingEntry{
        .{ .id = 0x6, .value = 1 },
        .{ .id = 0x6, .value = 2 },
    };
    try std.testing.expectError(Error.InvalidFrame, buildSettingsPayload(a, &duplicate));
    const reserved = [_]SettingEntry{.{ .id = 0x2, .value = 0 }};
    try std.testing.expectError(Error.InvalidFrame, buildSettingsPayload(a, &reserved));
}

test "frame payload validation enforces integer-only frame payloads" {
    const a = std.testing.allocator;
    const empty = try validateFramePayload(a, 0x0, "");
    defer a.free(empty);

    try std.testing.expectError(Error.Truncated, validateFramePayload(a, 0x7, "\x40"));
    try std.testing.expectError(Error.InvalidFrame, validateFramePayload(a, 0x7, "\x01\x00"));

    const unknown = try validateFramePayload(a, 0x2A, "arbitrary extension payload");
    defer a.free(unknown);
}
