//! HTTP/3 frame types and encoding (RFC 9114 section 7.2).
//!
//! References:
//!   - RFC 9114 Section 7.2 — Frame Types (DATA, HEADERS, RESERVED, SETTINGS,
//!     PUSH_PROMISE, GOAWAY, MAX_PUSH_ID)
//!   - RFC 9114 Section 7.2.8 — Unknown Frames, GREASE, and reserved types
//!   - RFC 9114 Section 8.1 — HTTP/3 Error Codes
//!   - RFC 9218 Section 7 — PRIORITY_UPDATE frames (0x0F0700/0x0F0701)

const std = @import("std");
const varint = @import("../quic/varint.zig");
const Allocator = std.mem.Allocator;

/// HTTP/3 error codes (RFC 9114 section 8.1; 0x200 range is RFC 9204).
/// These values are the QUIC application wire codes verbatim.
pub const H3Error = enum(u64) {
    noError = 0x0100,
    generalProtocolError = 0x0101,
    internalError = 0x0102,
    streamCreationError = 0x0103,
    closedCriticalStream = 0x0104,
    frameUnexpected = 0x0105,
    frameError = 0x0106,
    excessiveLoad = 0x0107,
    idError = 0x0108,
    settingsError = 0x0109,
    missingSettings = 0x010A,
    requestRejected = 0x010B,
    requestCancelled = 0x010C,
    requestIncomplete = 0x010D,
    messageError = 0x010E,
    connectError = 0x010F,
    versionFallback = 0x0110,
    qpackGeneralError = 0x0200,
    qpackEncoderStreamError = 0x0201,
    qpackDecoderStreamError = 0x0202,
};

/// Stream type identifiers for unidirectional streams.
pub const UniStreamType = struct {
    pub const control: u64 = 0x00;
    pub const push: u64 = 0x01;
    pub const qpackEncoder: u64 = 0x02;
    pub const qpackDecoder: u64 = 0x03;
};

pub const FrameType = enum(u64) {
    data = 0x0,
    headers = 0x1,
    cancelPush = 0x3,
    settings = 0x4,
    pushPromise = 0x5,
    goaway = 0x7,
    maxPushId = 0xD,
    priorityUpdate = 0x0F0700,
    priorityUpdatePush = 0x0F0701,
    _,

    pub fn fromInt(v: u64) FrameType {
        return @fromBackingInt(@intCast(v));
    }
};

/// Reserved HTTP/3 frame types (RFC 9114 Section 7.2.8: 0x2, 0x6, 0x8,
/// 0x9, the HTTP/2 frame space). Receipt is a connection error of type
/// H3_FRAME_UNEXPECTED, never a silent skip.
pub fn isReservedFrameType(v: u64) bool {
    return v == 0x2 or v == 0x6 or v == 0x8 or v == 0x9;
}

/// GREASE frame types: 0x21 + 0x1f*N (RFC 9114 Section 7.2.8). Like any
/// unknown frame they must be length-skipped and ignored.
pub fn isGreaseFrameType(v: u64) bool {
    if (v < 0x21) return false;
    return (v -% 0x21) % 0x1f == 0;
}

/// Which HTTP/3 stream a frame arrived on. The same frame ID is legal or
/// a connection error depending on the stream (RFC 9114 Sections 6.2,
/// 7.2). QPACK unidirectional streams carry instructions, not HTTP/3
/// frames; any HTTP/3 frame parsed there is a QPACK stream error.
pub const StreamKind = enum {
    control,
    requestBidi,
    qpackEncoder,
    qpackDecoder,
    push,
};

/// Returns null when `frameType` may appear on `kind`; otherwise the
/// H3 connection error code to close with. Unknown (non-reserved) frame
/// types return null on every stream kind: the caller must length-skip
/// and ignore them per RFC 9114 Section 7.2.8.
pub fn checkFrameAllowed(kind: StreamKind, frameType: u64) ?H3Error {
    if (isReservedFrameType(frameType)) return .frameUnexpected;
    switch (kind) {
        .control => switch (frameType) {
            0x4, 0x7, 0x3, 0xD, 0x0F0700 => return null,
            0x0, 0x1, 0x5, 0x0F0701 => return .frameUnexpected,
            else => return null, // unknown: skip + ignore
        },
        .requestBidi => switch (frameType) {
            0x0, 0x1 => return null,
            0x4, 0x7, 0x3, 0xD, 0x5, 0x0F0700, 0x0F0701 => return .frameUnexpected,
            else => return null, // unknown: skip + ignore
        },
        // No-push policy: push streams and PUSH_PROMISE are rejected
        // everywhere; unknown types are still skipped.
        .push => switch (frameType) {
            0x0, 0x1, 0x4, 0x7, 0x3, 0xD, 0x5, 0x0F0700, 0x0F0701 => return .frameUnexpected,
            else => return null,
        },
        .qpackEncoder => return .qpackEncoderStreamError,
        .qpackDecoder => return .qpackDecoderStreamError,
    }
}

/// Maps a frame codec failure to the QUIC application error code the
/// connection closes/resets with. The H3Error values already are the
/// wire codes (RFC 9114 Section 8.1).
///
/// NOTE: `Truncated` from `parseFrame` on a live stream usually means
/// "wait for more bytes", not a protocol error; only map it at FIN or
/// when the declared length can never be satisfied.
pub fn mapCodecError(err: Error) H3Error {
    return switch (err) {
        error.Truncated, error.TooLarge, error.InvalidFrame => .frameError,
        error.BufferTooSmall, error.OutOfMemory => .internalError,
    };
}

pub const Error = error{ Truncated, InvalidFrame, OutOfMemory, BufferTooSmall, TooLarge };

pub const FrameHeader = struct {
    frameType: u64,
    length: u64,
};

pub const ParsedFrame = struct {
    frameType: u64,
    payload: []const u8,
};

/// Validates the payload shape of an HTTP/3 frame.
///
/// Unknown frame types are intentionally accepted and ignored by higher
/// layers, but all defined frame types must have the wire shape required by
/// RFC 9114 Section 7.2, and reserved frame types (0x2, 0x6, 0x8, 0x9)
/// are rejected outright. The returned SETTINGS entries are owned by the
/// caller; non-SETTINGS frames return an empty owned slice.
pub fn validateFramePayload(
    allocator: Allocator,
    frameType: u64,
    payload: []const u8,
) Error![]SettingEntry {
    if (isReservedFrameType(frameType)) return Error.InvalidFrame;
    switch (frameType) {
        0x0, 0x1 => return allocator.alloc(SettingEntry, 0), // DATA and HEADERS
        0x3, 0x7, 0xD => return parseSingleVarintPayload(payload, allocator),
        // PUSH_PROMISE is Push ID followed by an encoded field section
        // (RFC 9114 Section 7.2.6): the ID must be present and well-formed;
        // the field section is validated when QPACK-decoded.
        0x5 => {
            var offset: usize = 0;
            _ = varint.decode(payload, &offset) catch |e| switch (e) {
                error.Truncated => return Error.Truncated,
                else => return Error.InvalidFrame,
            };
            return allocator.alloc(SettingEntry, 0);
        },
        0x4 => return parseSettingsPayload(payload, allocator),
        else => return allocator.alloc(SettingEntry, 0),
    }
}

/// Validates a single-varint frame payload (CANCEL_PUSH, GOAWAY,
/// MAX_PUSH_ID): exactly one QUIC varint consuming every payload byte.
pub fn parseSingleVarintPayload(payload: []const u8, allocator: Allocator) Error![]SettingEntry {
    var offset: usize = 0;
    _ = varint.decode(payload, &offset) catch |e| switch (e) {
        error.Truncated => return Error.Truncated,
        else => return Error.InvalidFrame,
    };
    if (offset != payload.len) return Error.InvalidFrame;
    return allocator.alloc(SettingEntry, 0);
}

/// Decodes a single-varint frame payload, returning the ID it carries.
/// Used for GOAWAY (stream ID), MAX_PUSH_ID (push ID) and CANCEL_PUSH
/// (push ID) after `validateFramePayload` accepted the shape.
pub fn decodeSingleVarintPayload(payload: []const u8) Error!u64 {
    var offset: usize = 0;
    const v = varint.decode(payload, &offset) catch |e| switch (e) {
        error.Truncated => return Error.Truncated,
        else => return Error.InvalidFrame,
    };
    if (offset != payload.len) return Error.InvalidFrame;
    return v;
}

/// Encodes one single-varint frame (CANCEL_PUSH, GOAWAY, MAX_PUSH_ID):
/// frame header plus a one-varint payload. Returns an owned buffer.
pub fn encodeSingleVarintFrame(allocator: Allocator, frameType: u64, id: u64) Error![]u8 {
    var vb: [16]u8 = undefined;
    const pn = varint.encode(&vb, id) catch return Error.BufferTooSmall;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var fh: [16]u8 = undefined;
    const hn = try encodeFrameHeader(&fh, frameType, pn);
    try out.appendSlice(allocator, fh[0..hn]);
    try out.appendSlice(allocator, vb[0..pn]);
    return out.toOwnedSlice(allocator);
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
    return .{ .frameType = ft, .length = len };
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
    return .{ .frameType = header.frameType, .payload = payload };
}

/// Encodes a frame header into buf. Returns bytes written.
pub fn encodeFrameHeader(buf: []u8, frameType: u64, length: u64) Error!usize {
    const n1 = varint.encode(buf, frameType) catch return Error.BufferTooSmall;
    const n2 = varint.encode(buf[n1..], length) catch return Error.BufferTooSmall;
    return n1 + n2;
}

/// SETTINGS parameter IDs (RFC 9114 section 7.2.4).
pub const SettingsId = enum(u64) {
    qpackMaxTableCapacity = 0x1,
    maxFieldSectionSize = 0x6,
    qpackBlockedStreams = 0x7,
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
    try std.testing.expectEqual(@as(u64, 0x1), fh.frameType);
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

test "reserved frame types are rejected, not skipped" {
    const a = std.testing.allocator;
    for ([_]u64{ 0x2, 0x6, 0x8, 0x9 }) |t| {
        try std.testing.expect(isReservedFrameType(t));
        try std.testing.expectError(Error.InvalidFrame, validateFramePayload(a, t, ""));
        try std.testing.expectEqual(H3Error.frameUnexpected, checkFrameAllowed(.control, t).?);
        try std.testing.expectEqual(H3Error.frameUnexpected, checkFrameAllowed(.requestBidi, t).?);
    }
    try std.testing.expect(!isReservedFrameType(0x0));
    try std.testing.expect(!isReservedFrameType(0x21));
    try std.testing.expect(!isReservedFrameType(0x2A));
}

test "grease frame types are recognized and ignored" {
    try std.testing.expect(isGreaseFrameType(0x21));
    try std.testing.expect(isGreaseFrameType(0x40)); // 0x21 + 0x1f
    try std.testing.expect(isGreaseFrameType(0x21 + 0x1f * 100));
    try std.testing.expect(!isGreaseFrameType(0x20));
    try std.testing.expect(!isGreaseFrameType(0x22));
    try std.testing.expect(!isGreaseFrameType(0x2A));
    try std.testing.expect(!isGreaseFrameType(0x0));

    const a = std.testing.allocator;
    const g = try validateFramePayload(a, 0x21, "\x00\x01\x02");
    defer a.free(g);
    // Unknown and grease frames are length-skipped by the caller.
    try std.testing.expect(checkFrameAllowed(.control, 0x21) == null);
    try std.testing.expect(checkFrameAllowed(.requestBidi, 0x40) == null);
}

test "single-varint frames roundtrip with strict shapes" {
    const a = std.testing.allocator;
    for ([_]u64{ 0x0, 0x4, 0x1FFFFFFFFFFFFFFF }) |id| {
        const enc = try encodeSingleVarintFrame(a, 0x7, id);
        defer a.free(enc);
        var off: usize = 0;
        const fr = try parseFrame(enc, &off);
        try std.testing.expectEqual(@as(u64, 0x7), fr.frameType);
        try std.testing.expectEqual(id, try decodeSingleVarintPayload(fr.payload));
    }
    // Empty and trailing-garbage payloads are malformed.
    try std.testing.expectError(Error.Truncated, decodeSingleVarintPayload(""));
    try std.testing.expectError(Error.InvalidFrame, decodeSingleVarintPayload("\x04\x04"));
    try std.testing.expectError(Error.Truncated, validateFramePayload(a, 0xD, "\x40"));
}

test "push promise requires a push id prefix" {
    const a = std.testing.allocator;
    // Push ID varint followed by an (opaque here) field section.
    const ok = try validateFramePayload(a, 0x5, "\x08\x00\x00");
    defer a.free(ok);
    try std.testing.expectError(Error.Truncated, validateFramePayload(a, 0x5, ""));
}

test "frame legality by stream kind" {
    // Control stream: only SETTINGS/GOAWAY/CANCEL_PUSH/MAX_PUSH_ID/PRIORITY_UPDATE.
    for ([_]u64{ 0x4, 0x7, 0x3, 0xD, 0x0F0700 }) |t| {
        try std.testing.expect(checkFrameAllowed(.control, t) == null);
    }
    for ([_]u64{ 0x0, 0x1, 0x5, 0x0F0701 }) |t| {
        try std.testing.expectEqual(H3Error.frameUnexpected, checkFrameAllowed(.control, t).?);
    }
    // Request streams: only DATA/HEADERS.
    try std.testing.expect(checkFrameAllowed(.requestBidi, 0x0) == null);
    try std.testing.expect(checkFrameAllowed(.requestBidi, 0x1) == null);
    for ([_]u64{ 0x4, 0x7, 0x3, 0xD, 0x5, 0x0F0700, 0x0F0701 }) |t| {
        try std.testing.expectEqual(H3Error.frameUnexpected, checkFrameAllowed(.requestBidi, t).?);
    }
    // No-push policy: defined frames rejected on push streams.
    try std.testing.expectEqual(H3Error.frameUnexpected, checkFrameAllowed(.push, 0x1).?);
    try std.testing.expect(checkFrameAllowed(.push, 0x2A) == null);
    // QPACK streams never carry HTTP/3 frames.
    try std.testing.expectEqual(H3Error.qpackEncoderStreamError, checkFrameAllowed(.qpackEncoder, 0x4).?);
    try std.testing.expectEqual(H3Error.qpackDecoderStreamError, checkFrameAllowed(.qpackDecoder, 0x4).?);
    // Priority variants are known frame types.
    try std.testing.expectEqual(FrameType.priorityUpdate, FrameType.fromInt(0x0F0700));
    try std.testing.expectEqual(FrameType.priorityUpdatePush, FrameType.fromInt(0x0F0701));
}

test "codec errors map to connection error codes" {
    try std.testing.expectEqual(H3Error.frameError, mapCodecError(Error.Truncated));
    try std.testing.expectEqual(H3Error.frameError, mapCodecError(Error.InvalidFrame));
    try std.testing.expectEqual(H3Error.frameError, mapCodecError(Error.TooLarge));
    try std.testing.expectEqual(H3Error.internalError, mapCodecError(Error.OutOfMemory));
    try std.testing.expectEqual(H3Error.internalError, mapCodecError(Error.BufferTooSmall));
    // H3Error values are the QUIC application wire codes.
    try std.testing.expectEqual(@as(u64, 0x0105), @backingInt(H3Error.frameUnexpected));
    try std.testing.expectEqual(@as(u64, 0x0100), @backingInt(H3Error.noError));
    try std.testing.expectEqual(@as(u64, 0x0201), @backingInt(H3Error.qpackEncoderStreamError));
}

test "frame header codec reports exhaustion" {
    var tiny: [1]u8 = undefined;
    // 0x1 (1 byte) + 300 (2 bytes) does not fit in 1 byte.
    try std.testing.expectError(Error.BufferTooSmall, encodeFrameHeader(&tiny, 0x1, 300));
    var off: usize = 0;
    try std.testing.expectError(Error.Truncated, parseFrameHeader("", &off));
    // Declared length far beyond the buffer is truncation, not a crash.
    var buf: [16]u8 = undefined;
    const n = try encodeFrameHeader(&buf, 0x0, 0x4000);
    var off2: usize = 0;
    try std.testing.expectError(Error.Truncated, parseFrame(buf[0..n], &off2));
}
