//! HTTP/2 framing layer (RFC 9113 Section 4, Section 6).
//!
//! Frame header parse/serialize plus typed payload decoding with strict
//! RFC 9113 validation: exact payload lengths where fixed, flag legality,
//! padding bounds, stream-id requirements, and SETTINGS value ranges.
//! Unknown frame types are surfaced to the session (which ignores them)
//! rather than rejected here.
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
    FrameSizeError,
    StreamFrameSizeError,
    StreamProtocolError,
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
    priorityUpdate = 0x10,
    _,

    pub fn toString(self: FrameType) []const u8 {
        if (@backingInt(self) <= 9 or @backingInt(self) == 0x10) return @tagName(self);
        return "unknown";
    }

    pub fn isKnown(self: FrameType) bool {
        return @backingInt(self) <= 9 or @backingInt(self) == 0x10;
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

/// Mask of flags valid for each known type; undefined bits are stripped
/// on receive.
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
        .priorityUpdate => 0,
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
        const ftRaw = buf[3];
        const ft: FrameType = @fromBackingInt(@intCast(ftRaw));
        const rawSid = std.mem.readInt(u32, buf[5..9], .big);
        var flags = buf[4];
        if (ft.isKnown()) flags &= validFlags(ft);
        return .{
            .length = length,
            .frameType = ft,
            .flags = flags,
            .streamId = @intCast(rawSid & 0x7FFFFFFF),
        };
    }

    pub fn serialize(self: *const FrameHeader, buf: *[FRAME_HEADER_SIZE]u8) void {
        buf[0] = @intCast((self.length >> 16) & 0xFF);
        buf[1] = @intCast((self.length >> 8) & 0xFF);
        buf[2] = @intCast(self.length & 0xFF);
        buf[3] = @backingInt(self.frameType);
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
    enableConnectProtocol = 0x8,
    _,
};

pub const SettingEntry = struct { id: u16, value: u32 };

/// Validates one setting value; returns the wire error code on violation
/// (null when fine). Unknown IDs pass through untouched (must be ignored).
pub fn validateSetting(id: SettingsId, value: u32) ?u32 {
    return switch (id) {
        .enablePush => if (value > 1) 1 else null, // PROTOCOL_ERROR
        .enableConnectProtocol => if (value > 1) 1 else null, // PROTOCOL_ERROR
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
    /// Payload length counted against flow control: application bytes plus
    /// the Pad Length field and trailing padding (RFC 9113 Section 6.9.1).
    flowLen: usize,
    endStream: bool,
};

pub const Headers = struct {
    block: []const u8,
    endStream: bool,
    endHeaders: bool,
    exclusive: bool = false,
    streamDep: u31 = 0,
    weight: u8 = 255,
    /// The HEADERS frame declared itself as its own priority dependency.
    /// The block still has to reach HPACK before the stream is reset.
    selfDependency: bool = false,
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

pub const PriorityUpdate = struct {
    prioritizedStreamId: u31,
    priorityFieldValue: []const u8,
};

/// RFC 9218: Extensible Prioritization Scheme for HTTP urgency and incremental parameters.
pub const PriorityValue = struct {
    urgency: u3 = 3,
    incremental: bool = false,

    pub fn parse(field: []const u8) PriorityValue {
        var pv = PriorityValue{};
        var iter = std.mem.splitScalar(u8, field, ',');
        while (iter.next()) |rawTok| {
            const tok = std.mem.trim(u8, rawTok, " \t");
            if (std.ascii.eqlIgnoreCase(tok, "i")) {
                pv.incremental = true;
            } else if (std.ascii.startsWithIgnoreCase(tok, "u=")) {
                const numStr = tok[2..];
                if (numStr.len == 1 and std.ascii.isDigit(numStr[0]) and numStr[0] < '8') {
                    pv.urgency = @intCast(numStr[0] - '0');
                }
            }
        }
        return pv;
    }

    pub fn format(self: PriorityValue, out: []u8) ![]const u8 {
        if (self.incremental) {
            return std.fmt.bufPrint(out, "u={d}, i", .{self.urgency});
        } else {
            return std.fmt.bufPrint(out, "u={d}", .{self.urgency});
        }
    }
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
    priorityUpdate: PriorityUpdate,
    unknown: Unknown,

    /// Parses the payload according to the header. Applies the RFC 9113 rules:
    ///   DATA/HEADERS/PUSH_PROMISE padding bounds -> PROTOCOL_ERROR
    ///   PRIORITY len==5, RST len==4, SETTINGS len%6==0 & !ACK-with-len,
    ///   PING len==8, GOAWAY len>=8, WINDOW_UPDATE len==4 & inc!=0 checked
    ///   by session (0 allowed at parse level? spec forbids; enforced here)
    pub fn parse(hdr: FrameHeader, payload: []const u8, allocator: Allocator) Error!Frame {
        // RFC 9113 Section 4.1: stream 0 is reserved for connection-level
        // frames, while request/stream frames require a non-zero identifier.
        switch (hdr.frameType) {
            .data, .headers, .priority, .rstStream, .pushPromise, .continuation => if (hdr.streamId == 0) return Error.InvalidStreamId,
            .settings, .ping, .goaway, .priorityUpdate => if (hdr.streamId != 0) return Error.InvalidStreamId,
            .windowUpdate => {}, // valid on stream 0 or a non-zero stream
            _ => {},
        }
        switch (hdr.frameType) {
            .data => {
                if (hdr.flags & PADDED_FLAG != 0) {
                    if (payload.len < 1) return Error.FrameSizeError;
                    const padLen = payload[0];
                    if (@as(usize, padLen) + 1 > payload.len) return Error.ProtocolError; // pad+field > len
                    return .{ .data = .{
                        .data = payload[1 .. payload.len - padLen],
                        .flowLen = payload.len,
                        .endStream = hdr.flags & END_FLAG != 0,
                    } };
                }
                return .{ .data = .{
                    .data = payload,
                    .flowLen = payload.len,
                    .endStream = hdr.flags & END_FLAG != 0,
                } };
            },
            .headers => {
                var rest = payload;
                var exclusive = false;
                var dep: u31 = 0;
                var weight: u8 = 255;
                if (hdr.flags & PADDED_FLAG != 0) {
                    if (rest.len < 1) return Error.FrameSizeError;
                    const padLen = rest[0];
                    if (@as(usize, padLen) + 1 > rest.len) return Error.ProtocolError;
                    rest = rest[1 .. rest.len - padLen];
                }
                if (hdr.flags & PRIORITY_F != 0) {
                    if (rest.len < 5) return Error.FrameSizeError;
                    const raw = std.mem.readInt(u32, rest[0..4], .big);
                    exclusive = raw >> 31 != 0;
                    dep = @intCast(raw & 0x7FFFFFFF);
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
                    .selfDependency = dep == hdr.streamId,
                } };
            },
            .priority => {
                if (payload.len != 5) return Error.StreamFrameSizeError;
                const raw = std.mem.readInt(u32, payload[0..4], .big);
                if ((raw & 0x7FFFFFFF) == hdr.streamId) return Error.StreamProtocolError;
                return .{ .priority = .{
                    .exclusive = raw >> 31 != 0,
                    .streamDep = @intCast(raw & 0x7FFFFFFF),
                    .weight = payload[4],
                } };
            },
            .rstStream => {
                if (payload.len != 4) return Error.FrameSizeError;
                return .{ .rstStream = .{ .errorCode = std.mem.readInt(u32, payload[0..4], .big) } };
            },
            .settings => {
                if (hdr.hasAck()) {
                    if (payload.len != 0) return Error.FrameSizeError;
                    return .{ .settings = &.{} };
                }
                if (payload.len % 6 != 0) return Error.FrameSizeError;
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
                    if (rest.len < 1) return Error.FrameSizeError;
                    const padLen = rest[0];
                    if (@as(usize, padLen) + 1 > rest.len) return Error.ProtocolError;
                    rest = rest[1 .. rest.len - padLen];
                }
                if (rest.len < 4) return Error.FrameSizeError;
                const promised = std.mem.readInt(u32, rest[0..4], .big) & 0x7FFFFFFF;
                if (promised == 0) return Error.InvalidStreamId;
                return .{ .pushPromise = .{
                    .promisedStreamId = @intCast(promised),
                    .block = rest[4..],
                    .endHeaders = hdr.flags & END_HEADERS != 0,
                } };
            },
            .ping => {
                if (payload.len != 8) return Error.FrameSizeError;
                var p: Ping = undefined;
                @memcpy(&p.opaqueData, payload[0..8]);
                return .{ .ping = p };
            },
            .goaway => {
                if (payload.len < 8) return Error.FrameSizeError;
                return .{ .goaway = .{
                    .lastStreamId = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF),
                    .errorCode = std.mem.readInt(u32, payload[4..8], .big),
                    .debugData = payload[8..],
                } };
            },
            .windowUpdate => {
                if (payload.len != 4) return Error.FrameSizeError;
                const inc = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;
                // A zero increment is a stream error on a non-zero stream
                // and a connection error on stream 0 (RFC 9113 Section 6.9).
                // The session classifies it so the right RST can be sent.
                return .{ .windowUpdate = .{ .increment = @intCast(inc) } };
            },
            .continuation => {
                return .{ .continuation = .{
                    .block = payload,
                    .endHeaders = hdr.flags & END_HEADERS != 0,
                } };
            },
            .priorityUpdate => {
                if (payload.len < 4) return Error.FrameSizeError;
                const prioritized = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;
                if (prioritized == 0) return Error.InvalidStreamId;
                return .{ .priorityUpdate = .{
                    .prioritizedStreamId = @intCast(prioritized),
                    .priorityFieldValue = payload[4..],
                } };
            },
            // RFC 9113 Section 4.1: extensions and unknown frame types are
            // ignored after their length-delimited payload is consumed.
            _ => return .{ .unknown = .{
                .frameType = @backingInt(hdr.frameType),
                .flags = hdr.flags,
                .payload = payload,
            } },
        }
    }
};

// Writers

pub fn writeHeader(out: *std.ArrayList(u8), gpa: Allocator, length: usize, t: FrameType, flags: u8, streamId: u31) !void {
    if (length > MAX_ALLOWED_FRAME_SIZE) return Error.FrameTooLarge;
    var h: FrameHeader = .{ .length = @intCast(length), .frameType = t, .flags = flags, .streamId = streamId };
    var b: [FRAME_HEADER_SIZE]u8 = undefined;
    h.serialize(&b);
    try out.appendSlice(gpa, &b);
}

pub fn writeData(out: *std.ArrayList(u8), gpa: Allocator, sid: u31, data: []const u8, endStream: bool) !void {
    if (data.len > MAX_ALLOWED_FRAME_SIZE) return Error.FrameTooLarge;
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
    if (entries.len > MAX_ALLOWED_FRAME_SIZE / 6) return Error.FrameTooLarge;
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

pub fn writeGoaway(out: *std.ArrayList(u8), gpa: Allocator, lastSid: u31, code: u32, debugData: []const u8) !void {
    if (debugData.len > MAX_ALLOWED_FRAME_SIZE - 8) return Error.FrameTooLarge;
    try writeHeader(out, gpa, 8 + debugData.len, .goaway, 0, 0);
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], lastSid, .big);
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

pub fn writePriorityUpdate(out: *std.ArrayList(u8), gpa: Allocator, prioritizedStreamId: u31, priorityFieldValue: []const u8) !void {
    const len = 4 + priorityFieldValue.len;
    try writeHeader(out, gpa, len, .priorityUpdate, 0, 0);
    var streamBuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &streamBuf, prioritizedStreamId & 0x7FFFFFFF, .big);
    try out.appendSlice(gpa, &streamBuf);
    try out.appendSlice(gpa, priorityFieldValue);
}

// Tests

test "frame header roundtrip keeps type, flags and stream id" {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    const hdr = FrameHeader{ .length = 1234, .frameType = .headers, .flags = 0x05, .streamId = 0x7FFFFFFF };
    hdr.serialize(&buf);
    const back = FrameHeader.parse(&buf);
    try std.testing.expectEqual(@as(u24, 1234), back.length);
    try std.testing.expectEqual(FrameType.headers, back.frameType);
    try std.testing.expectEqual(@as(u8, 0x05), back.flags);
    try std.testing.expectEqual(@as(u31, 0x7FFFFFFF), back.streamId);
}

test "unknown frame flags are stripped for known types only" {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    const hdr = FrameHeader{ .length = 0, .frameType = .ping, .flags = 0xFE, .streamId = 0 };
    hdr.serialize(&buf);
    const back = FrameHeader.parse(&buf);
    // Only the ACK bit is meaningful for PING.
    try std.testing.expectEqual(@as(u8, 0), back.flags);

    const unknown = FrameHeader{ .length = 0, .frameType = @fromBackingInt(@intCast(0x42)), .flags = 0xFE, .streamId = 0 };
    unknown.serialize(&buf);
    const backUnknown = FrameHeader.parse(&buf);
    try std.testing.expectEqual(@as(u8, 0xFE), backUnknown.flags);
}

test "reserved bit of the stream identifier is ignored" {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    const hdr = FrameHeader{ .length = 0, .frameType = .data, .flags = 0, .streamId = 5 };
    hdr.serialize(&buf);
    buf[5] |= 0x80; // set the reserved high bit
    const back = FrameHeader.parse(&buf);
    try std.testing.expectEqual(@as(u31, 5), back.streamId);
}

test "frame length beyond the 24-bit maximum is rejected" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(Error.FrameTooLarge, writeHeader(&out, std.testing.allocator, MAX_ALLOWED_FRAME_SIZE + 1, .data, 0, 1));
    // A short DATA frame is legal; the length guard only trips past the
    // 24-bit maximum, which is covered by writeHeader above.
    const eight: [8]u8 = @splat(0);
    try writeData(&out, std.testing.allocator, 1, &eight, false);
    try std.testing.expectEqual(@as(usize, 9 + 8), out.items.len);
}

test "malformed payloads are rejected by the frame parser" {
    const a = std.testing.allocator;
    const hdr = FrameHeader{ .length = 0, .frameType = .ping, .flags = 0, .streamId = 0 };
    try std.testing.expectError(Error.FrameSizeError, Frame.parse(hdr, &[_]u8{ 0, 0, 0 }, a));

    const settings = FrameHeader{ .length = 0, .frameType = .settings, .flags = 0, .streamId = 0 };
    try std.testing.expectError(Error.FrameSizeError, Frame.parse(settings, &[_]u8{ 0, 0, 0, 0, 0 }, a));

    const rst = FrameHeader{ .length = 0, .frameType = .rstStream, .flags = 0, .streamId = 1 };
    try std.testing.expectError(Error.FrameSizeError, Frame.parse(rst, &[_]u8{ 0, 0, 0 }, a));

    const goaway = FrameHeader{ .length = 0, .frameType = .goaway, .flags = 0, .streamId = 0 };
    try std.testing.expectError(Error.FrameSizeError, Frame.parse(goaway, &[_]u8{ 0, 0, 0 }, a));

    const prio = FrameHeader{ .length = 0, .frameType = .priority, .flags = 0, .streamId = 1 };
    try std.testing.expectError(Error.StreamFrameSizeError, Frame.parse(prio, &[_]u8{ 0, 0, 0 }, a));

    const selfDep: [5]u8 = .{ 0, 0, 0, 1, 16 };
    try std.testing.expectError(Error.StreamProtocolError, Frame.parse(prio, &selfDep, a));

    const data0 = FrameHeader{ .length = 0, .frameType = .data, .flags = 0, .streamId = 0 };
    try std.testing.expectError(Error.InvalidStreamId, Frame.parse(data0, "", a));
}

test "padded DATA reports padding as flow-controlled bytes" {
    const a = std.testing.allocator;
    const hdr = FrameHeader{ .length = 6, .frameType = .data, .flags = Flags.PADDED, .streamId = 1 };
    const f = try Frame.parse(hdr, &[_]u8{ 2, 'a', 'b', 'c', 0, 0 }, a);
    try std.testing.expectEqualStrings("abc", f.data.data);
    try std.testing.expectEqual(@as(usize, 6), f.data.flowLen);
}

test "padding longer than the payload is a protocol error" {
    const a = std.testing.allocator;
    const hdr = FrameHeader{ .length = 3, .frameType = .data, .flags = Flags.PADDED, .streamId = 1 };
    try std.testing.expectError(Error.ProtocolError, Frame.parse(hdr, &[_]u8{ 0x10, 'a', 'b' }, a));
}

test "settings payload must be a multiple of six bytes" {
    const a = std.testing.allocator;
    const hdr = FrameHeader{ .length = 6, .frameType = .settings, .flags = 0, .streamId = 0 };
    const f = try Frame.parse(hdr, &[_]u8{ 0, 3, 0, 0, 0, 100 }, a);
    defer a.free(f.settings);
    try std.testing.expectEqual(@as(usize, 1), f.settings.len);
    try std.testing.expectEqual(@as(u16, 3), f.settings[0].id);
    try std.testing.expectEqual(@as(u32, 100), f.settings[0].value);
}

test "setting values are validated against the RFC ranges" {
    try std.testing.expectEqual(@as(?u32, 1), validateSetting(.enablePush, 2));
    try std.testing.expectEqual(@as(?u32, null), validateSetting(.enablePush, 1));
    try std.testing.expectEqual(@as(?u32, 3), validateSetting(.initialWindowSize, @intCast(MAX_WINDOW + 1)));
    try std.testing.expectEqual(@as(?u32, null), validateSetting(.initialWindowSize, @intCast(MAX_WINDOW)));
    try std.testing.expectEqual(@as(?u32, 1), validateSetting(.maxFrameSize, DEFAULT_MAX_FRAME_SIZE - 1));
    try std.testing.expectEqual(@as(?u32, 1), validateSetting(.maxFrameSize, @intCast(MAX_ALLOWED_FRAME_SIZE + 1)));
    try std.testing.expectEqual(@as(?u32, null), validateSetting(.maxFrameSize, DEFAULT_MAX_FRAME_SIZE));
    try std.testing.expectEqual(@as(?u32, 1), validateSetting(.enableConnectProtocol, 2));
    try std.testing.expectEqual(@as(?u32, null), validateSetting(.enableConnectProtocol, 1));
}

test "priority update frame roundtrip and PriorityValue parse/format" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);

    try writePriorityUpdate(&out, a, 5, "u=1, i");

    const hdr = FrameHeader.parse(out.items[0..FRAME_HEADER_SIZE]);
    try std.testing.expectEqual(FrameType.priorityUpdate, hdr.frameType);
    try std.testing.expectEqual(@as(u31, 0), hdr.streamId);

    const f = try Frame.parse(hdr, out.items[FRAME_HEADER_SIZE..], a);
    try std.testing.expectEqual(@as(u31, 5), f.priorityUpdate.prioritizedStreamId);
    try std.testing.expectEqualStrings("u=1, i", f.priorityUpdate.priorityFieldValue);

    const parsedPv = PriorityValue.parse(f.priorityUpdate.priorityFieldValue);
    try std.testing.expectEqual(@as(u3, 1), parsedPv.urgency);
    try std.testing.expect(parsedPv.incremental);

    var formattedBuf: [32]u8 = undefined;
    const formatted = try parsedPv.format(&formattedBuf);
    try std.testing.expectEqualStrings("u=1, i", formatted);
}
