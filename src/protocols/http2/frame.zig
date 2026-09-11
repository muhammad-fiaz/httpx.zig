//! HTTP/2 framing layer (RFC 9113 Section 4, Section 6).
//!
//! Frame header parse/serialize plus typed payload decoding with the
//! validation rules nghttp2 enforces: exact payload lengths where fixed,
//! flag legality, padding bounds, stream-id requirements, SETTINGS value
//! ranges. Unknown frame types are surfaced to the session (which ignores
//! them) rather than rejected here.
//!
//! References:
//!   - RFC 9113 Section 4 — Frame Format (9-byte header + payload)
//!   - RFC 9113 Section 6 — Frame Definitions (DATA, HEADERS, PRIORITY, RST_STREAM,
//!     PUSHPromise, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION, SETTINGS)
//!   - RFC 9113 Section 6.5 — SETTINGS (settings parameters and ranges)
//!   - RFC 9113 Section 6.9 — WINDOW_UPDATE (flow control window)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    FrameTooLarge,
    InvalidFrameType,
    InvalidStreamId,
    InvalidPayload,
    ProtocolError,
    OutOfMemory,
};

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rstStream = 0x3,
    settings = 0x4,
    pushPromise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    windowUpdate = 0x8,
    continuation = 0x9,
    _,

    pub fn toString(self: FrameType) []const u8 {
        if (@intFromEnum(self) <= 9) return @tagName(self);
        return "unknown";
    }

    pub fn isKnown(self: FrameType) bool {
        return @intFromEnum(self) <= 9;
    }
};

pub const Flags = struct {
    pub const ACK: u8 = 0x01;
    pub const END_STREAM: u8 = 0x01;
    pub const END_HEADERS: u8 = 0x04;
    pub const PADDED: u8 = 0x08;
    pub const PRIORITY: u8 = 0x20;
};

pub const FRAME_HEADER_SIZE: usize = 9;
pub const DEFAULT_MAX_FRAME_SIZE: usize = 16384;
pub const MAX_ALLOWED_FRAME_SIZE: usize = 16777215;
pub const MAX_WINDOW: i64 = 0x7FFFFFFF;
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Mask of flags valid for each known type; unknown bits are stripped on
/// receive exactly like nghttp2.
pub fn validFlags(t: FrameType) u8 {
    return switch (t) {
        .data => END_FLAG | PADDED_FLAG,
        .headers => END_FLAG | END_HEADERS | PADDED_FLAG | PRIORITY_F,
        .priority => 0,
        .rstStream => 0,
        .settings => ACK,
        .pushPromise => END_HEADERS | PADDED_FLAG,
        .ping => ACK,
        .goaway => 0,
        .windowUpdate => 0,
        .continuation => END_HEADERS,
        _ => 0xFF, // unknown types: leave untouched
    };
}

const END_FLAG: u8 = Flags.END_STREAM;
const PADDED_FLAG: u8 = Flags.PADDED;
const END_HEADERS: u8 = Flags.END_HEADERS;
const PRIORITY_F: u8 = Flags.PRIORITY;
const ACK: u8 = Flags.ACK;

pub const FrameHeader = struct {
    length: u24,
    frameType: FrameType,
    /// Only valid bits retained.
    flags: u8,
    streamId: u31,

    pub fn parse(buf: *const [FRAME_HEADER_SIZE]u8) FrameHeader {
        const length: u24 = (@as(u24, buf[0]) << 16) | (@as(u24, buf[1]) << 8) | buf[2];
        const ft_raw = buf[3];
        const ft: FrameType = @enumFromInt(ft_raw);
        const raw_sid = std.mem.readInt(u32, buf[5..9], .big);
        var flags = buf[4];
        if (ft.isKnown()) flags &= validFlags(ft);
        return .{
            .length = length,
            .frameType = ft,
            .flags = flags,
            .streamId = @intCast(raw_sid & 0x7FFFFFFF),
        };
    }

    pub fn serialize(self: *const FrameHeader, buf: *[FRAME_HEADER_SIZE]u8) void {
        buf[0] = @intCast((self.length >> 16) & 0xFF);
        buf[1] = @intCast((self.length >> 8) & 0xFF);
        buf[2] = @intCast(self.length & 0xFF);
        buf[3] = @intFromEnum(self.frameType);
        buf[4] = self.flags;
        std.mem.writeInt(u32, buf[5..9], self.streamId, .big);
    }

    pub fn hasEndStream(self: FrameHeader) bool {
        return switch (self.frameType) {
            .headers, .data => self.flags & END_FLAG != 0,
            else => false,
        };
    }

    pub fn hasAck(self: FrameHeader) bool {
        return switch (self.frameType) {
            .settings, .ping => self.flags & ACK != 0,
            else => false,
        };
    }

    pub fn hasEndHeaders(self: FrameHeader) bool {
        return switch (self.frameType) {
            .headers, .pushPromise, .continuation => self.flags & END_HEADERS != 0,
            else => false,
        };
    }
};

// SETTINGS

pub const SettingsId = enum(u16) {
    headerTableSize = 0x1,
    enablePush = 0x2,
    maxConcurrentStreams = 0x3,
    initialWindowSize = 0x4,
    maxFrameSize = 0x5,
    maxHeaderListSize = 0x6,
    _,
};

pub const SettingEntry = struct { id: u16, value: u32 };

/// Validates one setting value; returns the wire error code on violation
/// (null when fine). Unknown IDs pass through untouched (must be ignored).
pub fn validateSetting(id: SettingsId, value: u32) ?u32 {
    return switch (id) {
        .enablePush => if (value > 1) 1 else null, // PROTOCOL_ERROR
        .initialWindowSize => if (value > MAX_WINDOW) 3 else null, // FLOW_CONTROL_ERROR
        .maxFrameSize => if (value < DEFAULT_MAX_FRAME_SIZE or value > MAX_ALLOWED_FRAME_SIZE) 1 else null,
        else => null,
    };
}

pub fn serializeSetting(buf: *[6]u8, id: u16, value: u32) void {
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u32, buf[2..6], value, .big);
}

// Typed payloads

pub const Data = struct {
    data: []const u8,
    endStream: bool,
};

pub const Headers = struct {
    block: []const u8,
    endStream: bool,
    endHeaders: bool,
    exclusive: bool = false,
    streamDep: u31 = 0,
    weight: u8 = 255,
};

pub const Priority = struct {
    exclusive: bool,
    streamDep: u31,
    weight: u8,
};

pub const RstStream = struct { errorCode: u32 };

pub const Ping = struct { opaqueData: [8]u8 };

pub const Goaway = struct {
    lastStreamId: u31,
    errorCode: u32,
    debugData: []const u8,
};

pub const WindowUpdate = struct { increment: u31 };

pub const PushPromise = struct {
    promisedStreamId: u31,
    block: []const u8,
    endHeaders: bool,
};

pub const Continuation = struct {
    block: []const u8,
    endHeaders: bool,
};

pub const Unknown = struct {
    frameType: u8,
    flags: u8,
    payload: []const u8,
};

/// Decoded frame view; slices reference the session's input buffer.
pub const Frame = union(enum) {
    data: Data,
    headers: Headers,
    priority: Priority,
    rstStream: RstStream,
    settings: []SettingEntry,
    pushPromise: PushPromise,
    ping: Ping,
    goaway: Goaway,
    windowUpdate: WindowUpdate,
    continuation: Continuation,
    unknown: Unknown,

    /// Parses the payload according to the header. Applies nghttp2's rules:
    ///   DATA/HEADERS/PUSH_PROMISE padding bounds -> PROTOCOL_ERROR
    ///   PRIORITY len==5, RST len==4, SETTINGS len%6==0 & !ACK-with-len,
    ///   PING len==8, GOAWAY len>=8, WINDOW_UPDATE len==4 & inc!=0 checked
    ///   by session (0 allowed at parse level? spec forbids; enforced here)
    pub fn parse(hdr: FrameHeader, payload: []const u8, allocator: Allocator) Error!Frame {
        // RFC 9113 Section 4.1: stream 0 is reserved for connection-level
        // frames, while request/stream frames require a non-zero identifier.
        switch (hdr.frameType) {
            .data, .headers, .priority, .rstStream, .pushPromise, .continuation => if (hdr.streamId == 0) return Error.InvalidStreamId,
            .settings, .ping, .goaway => if (hdr.streamId != 0) return Error.InvalidStreamId,
            .windowUpdate => {}, // valid on stream 0 or a non-zero stream
            _ => {},
        }
        switch (hdr.frameType) {
            .data => {
                if (hdr.flags & PADDED_FLAG != 0) {
                    if (payload.len < 1) return Error.InvalidPayload;
                    const pad_len = payload[0];
                    if (@as(usize, pad_len) + 1 > payload.len) return Error.ProtocolError; // pad+field > len
                    return .{ .data = .{
                        .data = payload[1 .. payload.len - pad_len],
                        .endStream = hdr.flags & END_FLAG != 0,
                    } };
                }
                return .{ .data = .{
                    .data = payload,
                    .endStream = hdr.flags & END_FLAG != 0,
                } };
            },
            .headers => {
                var rest = payload;
                var exclusive = false;
                var dep: u31 = 0;
                var weight: u8 = 255;
                if (hdr.flags & PADDED_FLAG != 0) {
                    if (rest.len < 1) return Error.InvalidPayload;
                    const pad_len = rest[0];
                    if (@as(usize, pad_len) + 1 > rest.len) return Error.ProtocolError;
                    rest = rest[1 .. rest.len - pad_len];
                }
                if (hdr.flags & PRIORITY_F != 0) {
                    if (rest.len < 5) return Error.InvalidPayload;
                    const raw = std.mem.readInt(u32, rest[0..4], .big);
                    exclusive = raw >> 31 != 0;
                    dep = @intCast(raw & 0x7FFFFFFF);
                    if (dep == hdr.streamId) return Error.InvalidPayload;
                    weight = rest[4];
                    rest = rest[5..];
                }
                return .{ .headers = .{
                    .block = rest,
                    .endStream = hdr.flags & END_FLAG != 0,
                    .endHeaders = hdr.flags & END_HEADERS != 0,
                    .exclusive = exclusive,
                    .streamDep = dep,
                    .weight = weight,
                } };
            },
            .priority => {
                if (payload.len != 5) return Error.InvalidPayload;
                const raw = std.mem.readInt(u32, payload[0..4], .big);
                if ((raw & 0x7FFFFFFF) == hdr.streamId) return Error.InvalidPayload;
                return .{ .priority = .{
                    .exclusive = raw >> 31 != 0,
                    .streamDep = @intCast(raw & 0x7FFFFFFF),
                    .weight = payload[4],
                } };
            },
            .rstStream => {
                if (payload.len != 4) return Error.InvalidPayload;
                return .{ .rstStream = .{ .errorCode = std.mem.readInt(u32, payload[0..4], .big) } };
            },
            .settings => {
                if (hdr.hasAck()) {
                    if (payload.len != 0) return Error.InvalidPayload;
                    return .{ .settings = &.{} };
                }
                if (payload.len % 6 != 0) return Error.InvalidPayload;
                const count = payload.len / 6;
                const entries = try allocator.alloc(SettingEntry, count);
                errdefer allocator.free(entries);
                for (0..count) |i| {
                    entries[i] = .{
                        .id = std.mem.readInt(u16, payload[i * 6 ..][0..2], .big),
                        .value = std.mem.readInt(u32, payload[i * 6 + 2 ..][0..4], .big),
                    };
                }
                return .{ .settings = entries };
            },
            .pushPromise => {
                var rest = payload;
                if (hdr.flags & PADDED_FLAG != 0) {
                    if (rest.len < 1) return Error.InvalidPayload;
                    const pad_len = rest[0];
                    if (@as(usize, pad_len) + 1 > rest.len) return Error.ProtocolError;
                    rest = rest[1 .. rest.len - pad_len];
                }
                if (rest.len < 4) return Error.InvalidPayload;
                const promised = std.mem.readInt(u32, rest[0..4], .big) & 0x7FFFFFFF;
                if (promised == 0) return Error.InvalidStreamId;
                return .{ .pushPromise = .{
                    .promisedStreamId = @intCast(promised),
                    .block = rest[4..],
                    .endHeaders = hdr.flags & END_HEADERS != 0,
                } };
            },
            .ping => {
                if (payload.len != 8) return Error.InvalidPayload;
                var p: Ping = undefined;
                @memcpy(&p.opaqueData, payload[0..8]);
                return .{ .ping = p };
            },
            .goaway => {
                if (payload.len < 8) return Error.InvalidPayload;
                return .{ .goaway = .{
                    .lastStreamId = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF),
                    .errorCode = std.mem.readInt(u32, payload[4..8], .big),
                    .debugData = payload[8..],
                } };
            },
            .windowUpdate => {
                if (payload.len != 4) return Error.InvalidPayload;
                const inc = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;
                if (inc == 0) return Error.InvalidPayload;
                return .{ .windowUpdate = .{ .increment = @intCast(inc) } };
            },
            .continuation => {
                return .{ .continuation = .{
                    .block = payload,
                    .endHeaders = hdr.flags & END_HEADERS != 0,
                } };
            },
            // RFC 9113 Section 4.1: extensions and unknown frame types are
            // ignored after their length-delimited payload is consumed.
            _ => return .{ .unknown = .{
                .frameType = @intFromEnum(hdr.frameType),
                .flags = hdr.flags,
                .payload = payload,
            } },
        }
    }
};

// Writers

pub fn writeHeader(out: *std.ArrayList(u8), gpa: Allocator, length: usize, t: FrameType, flags: u8, streamId: u31) !void {
    var h: FrameHeader = .{ .length = @intCast(length), .frameType = t, .flags = flags, .streamId = streamId };
    var b: [FRAME_HEADER_SIZE]u8 = undefined;
    h.serialize(&b);
    try out.appendSlice(gpa, &b);
}

pub fn writeData(out: *std.ArrayList(u8), gpa: Allocator, sid: u31, data: []const u8, endStream: bool) !void {
    var flags: u8 = 0;
    if (endStream) flags |= END_FLAG;
    try writeHeader(out, gpa, data.len, .data, flags, sid);
    try out.appendSlice(gpa, data);
}

pub fn writeRstStream(out: *std.ArrayList(u8), gpa: Allocator, sid: u31, code: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], code, .big);
    try writeHeader(out, gpa, 4, .rstStream, 0, sid);
    try out.appendSlice(gpa, &b);
}

pub fn writeSettings(out: *std.ArrayList(u8), gpa: Allocator, entries: []const SettingEntry) !void {
    try writeHeader(out, gpa, entries.len * 6, .settings, 0, 0);
    var b: [6]u8 = undefined;
    for (entries) |e| {
        serializeSetting(&b, e.id, e.value);
        try out.appendSlice(gpa, &b);
    }
}

pub fn writeSettingsAck(out: *std.ArrayList(u8), gpa: Allocator) !void {
    try writeHeader(out, gpa, 0, .settings, ACK, 0);
}

pub fn writePing(out: *std.ArrayList(u8), gpa: Allocator, ack: bool, opaqueData: [8]u8) !void {
    try writeHeader(out, gpa, 8, .ping, if (ack) ACK else 0, 0);
    try out.appendSlice(gpa, &opaqueData);
}

pub fn writeWindowUpdate(out: *std.ArrayList(u8), gpa: Allocator, sid: u31, increment: u31) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], increment, .big);
    try writeHeader(out, gpa, 4, .windowUpdate, 0, sid);
    try out.appendSlice(gpa, &b);
}

pub fn writeGoaway(out: *std.ArrayList(u8), gpa: Allocator, last_sid: u31, code: u32, debugData: []const u8) !void {
    try writeHeader(out, gpa, 8 + debugData.len, .goaway, 0, 0);
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], last_sid, .big);
    std.mem.writeInt(u32, b[4..8], code, .big);
    try out.appendSlice(gpa, &b);
    try out.appendSlice(gpa, debugData);
}

pub fn writePriority(out: *std.ArrayList(u8), gpa: Allocator, sid: u31, p: Priority) !void {
    var b: [5]u8 = undefined;
    const raw: u32 = (@as(u32, if (p.exclusive) 1 else 0) << 31) | p.streamDep;
    std.mem.writeInt(u32, b[0..4], raw, .big);
    b[4] = p.weight;
    try writeHeader(out, gpa, 5, .priority, 0, sid);
    try out.appendSlice(gpa, &b);
}
