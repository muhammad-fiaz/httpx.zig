//! QUIC packet header parsing and serialization (RFC 9000 sections 17.2,
//! 17.3). Long headers: Initial(0), 0-RTT(1), Handshake(2), Retry(3).
//! Short header (1-RTT): fixed bit pattern 0b010000xx.
//!
//! Reserved-bit validation happens AFTER header-protection removal (see
//! protect.zig); the parse functions here assume unprotected input.
//! Version negotiation packets are handled separately by conn.zig.

const std = @import("std");
const varint = @import("varint.zig");

pub const Version = enum(u32) {
    version_1 = 0x00000001,
    version_2 = 0x6B3343CF,
    _,

    pub fn isSupported(v: u32) bool {
        return v == @intFromEnum(Version.version_1) or v == @intFromEnum(Version.version_2);
    }
};

pub const LongType = enum(u2) {
    initial = 0,
    zero_rtt = 1,
    handshake = 2,
    retry = 3,

    /// Wire type bits differ for QUIC v2 (RFC 9369 section 3.2).
    pub fn wireType(self: LongType, version: u32) u2 {
        if (version == 0x00000001) return @intFromEnum(self);
        // v2 mapping: Initial=1, 0-RTT=2, Handshake=3, Retry=0
        return switch (self) {
            .initial => 1,
            .zero_rtt => 2,
            .handshake => 3,
            .retry => 0,
        };
    }

    pub fn fromWire(version: u32, w: u2) LongType {
        if (version == 0x00000001) return @enumFromInt(w);
        return switch (w) {
            0 => .retry,
            1 => .initial,
            2 => .zero_rtt,
            else => .handshake,
        };
    }
};

pub const HeaderError = error{ Truncated, UnsupportedVersion, InvalidPacket, BufferTooSmall, TooLarge };

/// Parsed long header fields. Slices reference the input buffer.
pub const LongHeader = struct {
    type: LongType,
    version: u32,
    dcid: []const u8,
    scid: []const u8,
    token: []const u8 = "",
    /// Offset of the packet number within the buffer.
    pn_offset: usize = 0,
    /// Value of the Length varint: PN bytes + protected payload + tag.
    length: u64 = 0,
};

pub const ShortHeader = struct {
    /// Offset of the DCID (fixed length known from our own CIDs).
    dcid_offset: usize = 5,
    key_phase: bool = false,
    pn_offset: usize = 0,
    pn_len: usize = 0,
};

pub fn isLongHeader(first_byte: u8) bool {
    return (first_byte & 0x80) != 0;
}

pub const ParseResult = struct { header: LongHeader, payload_offset: usize };

fn take(data: []const u8, offset: *usize, length: u64) HeaderError![]const u8 {
    const len = std.math.cast(usize, length) orelse return HeaderError.TooLarge;
    if (offset.* > data.len or len > data.len - offset.*) return HeaderError.Truncated;
    const result = data[offset.*..][0..len];
    offset.* += len;
    return result;
}

/// Parses an UNPROTECTED long header starting at data[0]. Slices point
/// into data; `payload_offset` is where the packet number begins.
pub fn parseLongHeader(data: []const u8) HeaderError!ParseResult {
    if (data.len < 6) return HeaderError.Truncated;
    const first = data[0];
    const version = std.mem.readInt(u32, data[1..5], .big);
    if (!Version.isSupported(version)) return HeaderError.UnsupportedVersion;
    var offset: usize = 5;

    const pkt_type = LongType.fromWire(version, @truncate((first >> 4) & 0x3));

    var h = LongHeader{
        .type = pkt_type,
        .version = version,
        .dcid = "",
        .scid = "",
    };

    const dcid_len: usize = data[offset];
    offset += 1;
    if (dcid_len > 20) return HeaderError.InvalidPacket;
    h.dcid = try take(data, &offset, dcid_len);

    if (offset >= data.len) return HeaderError.Truncated;
    const scid_len: usize = data[offset];
    offset += 1;
    if (scid_len > 20) return HeaderError.InvalidPacket;
    h.scid = try take(data, &offset, scid_len);

    if (pkt_type == .initial) {
        const tok_len_raw = try varint.decode(data, &offset);
        h.token = try take(data, &offset, tok_len_raw);
    }

    const length_raw = try varint.decode(data, &offset);
    h.length = length_raw;

    // Packet number sits AFTER the Length varint.
    h.pn_offset = offset;

    // Retry/VN have no Length/PN; this parser handles Initial/0RTT/Handshake.
    if (pkt_type == .retry) return HeaderError.InvalidPacket;

    return .{ .header = h, .payload_offset = offset };
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub const BuildInfo = struct {
    type: LongType,
    version: u32,
    dcid: []const u8,
    scid: []const u8,
    token: []const u8 = "",
    pn_len: usize,
    /// Payload bytes INCLUDING the AEAD tag (Length field value minus pn).
    protected_payload_len: usize,
};

/// Writes the long header up to (not including) the packet number.
/// Returns the number of header bytes written; the caller appends
/// pn_len packet-number bytes then the protected payload.
pub fn writeLongHeader(buf: []u8, info: BuildInfo) HeaderError!usize {
    if (info.dcid.len > 20 or info.scid.len > 20) return HeaderError.InvalidPacket;
    if (info.pn_len == 0 or info.pn_len > 4) return HeaderError.InvalidPacket;
    const token_varint_len = if (info.type == .initial) varintWidth(info.token.len) else 0;
    const length_value = std.math.add(usize, info.protected_payload_len, info.pn_len) catch return HeaderError.TooLarge;
    const needed = 5 + 1 + info.dcid.len + 1 + info.scid.len + token_varint_len + info.token.len + varintWidth(length_value);
    if (buf.len < needed) return HeaderError.BufferTooSmall;

    const wt = info.type.wireType(info.version);
    buf[0] = 0xC0 | (@as(u8, wt) << 4) | (@as(u8, @intCast(info.pn_len - 1)) & 0x03);
    std.mem.writeInt(u32, buf[1..5], info.version, .big);

    var pos: usize = 5;
    buf[pos] = @intCast(info.dcid.len);
    pos += 1;
    @memcpy(buf[pos..][0..info.dcid.len], info.dcid);
    pos += info.dcid.len;

    buf[pos] = @intCast(info.scid.len);
    pos += 1;
    if (info.scid.len > 0) {
        @memcpy(buf[pos..][0..info.scid.len], info.scid);
        pos += info.scid.len;
    }

    if (info.type == .initial) {
        const n = try varint.encode(buf[pos..], info.token.len);
        pos += n;
        if (info.token.len > 0) {
            @memcpy(buf[pos..][0..info.token.len], info.token);
            pos += info.token.len;
        }
    }

    // Length covers PN bytes + protected payload (RFC 9000 17.2).
    const n = try varint.encode(buf[pos..], length_value);
    pos += n;
    return pos;
}

fn varintWidth(value: usize) usize {
    if (value <= 0x3F) return 1;
    if (value <= 0x3FFF) return 2;
    if (value <= 0x3FFFFFFF) return 4;
    return 8;
}

pub const ShortBuildInfo = struct {
    key_phase: bool = false,
    dcid: []const u8,
    pn_len: usize,
};

/// Writes the short header up to the packet number. Returns bytes written.
pub fn writeShortHeader(buf: []u8, info: ShortBuildInfo) HeaderError!usize {
    if (info.dcid.len > 20 or info.pn_len == 0 or info.pn_len > 4) return HeaderError.InvalidPacket;
    if (buf.len < 1 + info.dcid.len) return HeaderError.BufferTooSmall;
    buf[0] = 0x40 | (@as(u8, if (info.key_phase) 1 else 0) << 2) | @as(u8, @intCast(info.pn_len - 1));
    var pos: usize = 1;
    @memcpy(buf[pos..][0..info.dcid.len], info.dcid);
    pos += info.dcid.len;
    return pos;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "long header detection" {
    try std.testing.expect(isLongHeader(0xC3));
    try std.testing.expect(!isLongHeader(0x43));
}

test "long header write/parse roundtrip with token" {
    var buf: [128]u8 = undefined;
    const dcid = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    const scid = [_]u8{ 0x11, 0x22, 0x33 };
    const token = "some-token";

    const n = try writeLongHeader(buf[0..], .{
        .type = .initial,
        .version = 0x00000001,
        .dcid = dcid[0..],
        .scid = scid[0..],
        .token = token,
        .pn_len = 2,
        .protected_payload_len = 100,
    });

    const res = try parseLongHeader(buf[0..n]);
    try std.testing.expectEqual(LongType.initial, res.header.type);
    try std.testing.expectEqual(@as(u32, 1), res.header.version);
    try std.testing.expectEqualSlices(u8, dcid[0..], res.header.dcid);
    try std.testing.expectEqualSlices(u8, scid[0..], res.header.scid);
    try std.testing.expectEqualStrings(token, res.header.token);
    try std.testing.expectEqual(@as(u64, 102), res.header.length);
    try std.testing.expectEqual(@as(usize, n), res.payload_offset);
    try std.testing.expectEqual(@as(usize, n), res.header.pn_offset);
}

test "v2 wire type remapping roundtrips" {
    var buf: [64]u8 = undefined;
    const dcid = [_]u8{ 1, 2, 3, 4 };
    const n = try writeLongHeader(buf[0..], .{
        .type = .handshake,
        .version = 0x6B3343CF,
        .dcid = dcid[0..],
        .scid = "",
        .pn_len = 1,
        .protected_payload_len = 10,
    });
    // v2 Handshake wire type 3 -> first byte 0b1111_0000.
    try std.testing.expectEqual(@as(u8, 0xF0), buf[0]);

    const res = try parseLongHeader(buf[0..n]);
    try std.testing.expectEqual(LongType.handshake, res.header.type);
    try std.testing.expectEqual(@as(u32, 0x6B3343CF), res.header.version);
}

test "short header roundtrip" {
    var buf: [64]u8 = undefined;
    const dcid = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [4]u8{ 1, 2, 3, 4 };
    const n = try writeShortHeader(buf[0..], .{ .key_phase = true, .dcid = dcid[0..], .pn_len = 3 });
    try std.testing.expectEqual(@as(u8, 0x46), buf[0]); // 0x40 | kp(0x04) | pn_len-1(2)
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqualSlices(u8, dcid[0..], buf[1..n]);
}

test "truncated headers rejected cleanly at every cut" {
    var buf: [128]u8 = undefined;
    const n = try writeLongHeader(buf[0..], .{
        .type = .initial,
        .version = 0x00000001,
        .dcid = &.{ 1, 2, 3 },
        .scid = &.{},
        .token = "t",
        .pn_len = 1,
        .protected_payload_len = 5,
    });
    for (0..n) |cut| {
        try std.testing.expectError(
            HeaderError.Truncated,
            parseLongHeader(buf[0..cut]),
        );
    }
}
