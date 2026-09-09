//! WebSocket frame codec (RFC 6455 section 5).
//!
//! Frame layout: FIN RSV1-3 Opcode | MASK Len(7/16/64) | ExtLen MaskKey Payload
//!
//! References:
//!   - RFC 6455 Section 5 — Data Framing
//!   - RFC 6455 Section 5.2 — Base Framing Protocol

const std = @import("std");
const Allocator = std.mem.Allocator;
/// Frame opcodes (RFC 6455 section 5.2).
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return switch (self) {
            .close, .ping, .pong => true,
            else => false,
        };
    }
};

pub const Error = error{
    InvalidFrame,
    ProtocolViolation,
};

// Frames

pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    opcode: Opcode,
    masked: bool,
    payloadLen: u64,
    maskKey: ?[4]u8 = null,
};

/// Parses frame header at start of buf. Returns header + bytes consumed.
pub fn parseFrameHeader(buf: []const u8) Error!struct { hdr: FrameHeader, consumed: usize } {
    if (buf.len < 2) return Error.InvalidFrame;
    const b0 = buf[0];
    const b1 = buf[1];

    const hdr = FrameHeader{
        .fin = b0 & 0x80 != 0,
        .rsv1 = b0 & 0x40 != 0,
        .opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F))),
        .masked = b1 & 0x80 != 0,
        .payloadLen = b1 & 0x7F,
    };

    // Reject reserved opcodes and enforce control-frame wire invariants
    // before any payload allocation or masking work.
    if (@intFromEnum(hdr.opcode) == 0x3 or @intFromEnum(hdr.opcode) == 0x4 or
        @intFromEnum(hdr.opcode) == 0x5 or @intFromEnum(hdr.opcode) == 0x6 or
        @intFromEnum(hdr.opcode) == 0x7 or @intFromEnum(hdr.opcode) == 0xB or
        @intFromEnum(hdr.opcode) == 0xC or @intFromEnum(hdr.opcode) == 0xD or
        @intFromEnum(hdr.opcode) == 0xE or @intFromEnum(hdr.opcode) == 0xF) return Error.InvalidFrame;
    if (hdr.opcode.isControl() and (!hdr.fin or hdr.payloadLen > 125)) return Error.ProtocolViolation;

    var pos: usize = 2;
    var payloadLen: u64 = hdr.payloadLen;

    if (hdr.payloadLen == 126) {
        if (pos + 2 > buf.len) return Error.InvalidFrame;
        payloadLen = std.mem.readInt(u16, buf[pos..][0..2], .big);
        if (payloadLen < 126) return Error.ProtocolViolation;
        pos += 2;
    } else if (hdr.payloadLen == 127) {
        if (pos + 8 > buf.len) return Error.InvalidFrame;
        payloadLen = std.mem.readInt(u64, buf[pos..][0..8], .big);
        if (payloadLen & 0x8000000000000000 != 0 or payloadLen < 65536) return Error.ProtocolViolation;
        pos += 8;
    }

    if (hdr.opcode.isControl() and payloadLen > 125) return Error.ProtocolViolation;

    var maskKey: ?[4]u8 = null;
    if (hdr.masked) {
        if (pos + 4 > buf.len) return Error.InvalidFrame;
        maskKey = buf[pos..][0..4].*;
        pos += 4;
    }

    return .{
        .hdr = .{ .fin = hdr.fin, .rsv1 = hdr.rsv1, .opcode = hdr.opcode, .masked = hdr.masked, .payloadLen = payloadLen, .maskKey = maskKey },
        .consumed = pos,
    };
}

/// Serializes a frame header into out. Returns bytes written.
pub fn buildFrameHeader(out: []u8, fin: bool, opcode: Opcode, payloadLen: usize, maskKey: ?[4]u8) usize {
    var pos: usize = 0;
    var b0: u8 = @intFromEnum(opcode);
    if (fin) b0 |= 0x80;
    out[pos] = b0;
    pos += 1;

    if (payloadLen < 126) {
        out[pos] = @intCast(payloadLen);
        pos += 1;
    } else if (payloadLen <= 0xFFFF) {
        out[pos] = 126;
        pos += 1;
        std.mem.writeInt(u16, out[pos..][0..2], @intCast(payloadLen), .big);
        pos += 2;
    } else {
        out[pos] = 127;
        pos += 1;
        std.mem.writeInt(u64, out[pos..][0..8], payloadLen, .big);
        pos += 8;
    }

    if (maskKey) |mk| {
        out[1] |= 0x80; // MASK bit is the high bit of the second frame byte
        @memcpy(out[pos..][0..4], &mk);
        pos += 4;
    }
    return pos;
}

/// Applies XOR masking in place (client->server direction requires it).
pub fn applyMask(data: []u8, key: [4]u8) void {
    for (data, 0..) |*b, i| {
        b.* ^= key[i % 4];
    }
}

/// Generates a cryptographically random 16-byte key and base64 encodes it
/// (for Sec-WebSocket-Key). Output buffer must be >= 24 bytes.
pub fn generateKey(random: std.Random, out: *[24]u8) []const u8 {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    return std.base64.standard.Encoder.encode(out, &raw);
}

// Tests

test "frame header roundtrip small unmasked" {
    var buf: [16]u8 = undefined;
    const n = buildFrameHeader(&buf, true, .text, 5, null);

    const parsed = try parseFrameHeader(buf[0..n]);
    try std.testing.expect(parsed.hdr.fin);
    try std.testing.expectEqual(Opcode.text, parsed.hdr.opcode);
    try std.testing.expectEqual(@as(u64, 5), parsed.hdr.payloadLen);
    try std.testing.expect(!parsed.hdr.masked);
}

test "frame header roundtrip extended 16-bit len masked" {
    var buf: [16]u8 = undefined;
    const n = buildFrameHeader(&buf, false, .binary, 1000, [_]u8{ 1, 2, 3, 4 });

    const parsed = try parseFrameHeader(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 1000), parsed.hdr.payloadLen);
    try std.testing.expect(parsed.hdr.masked);
    const mk = parsed.hdr.maskKey.?;
    try std.testing.expectEqual(@as(u8, 1), mk[0]);
}

test "mask apply/revert symmetric" {
    var data: [11]u8 = "hello world".*;
    const key = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const original = data;

    applyMask(&data, key);
    try std.testing.expect(!std.mem.eql(u8, &data, &original));
    applyMask(&data, key);
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "control frames must be final and at most 125 bytes" {
    var not_final = [_]u8{ 0x09, 0x00 };
    try std.testing.expectError(Error.ProtocolViolation, parseFrameHeader(&not_final));

    var too_large = [_]u8{ 0x89, 126, 0, 126 };
    try std.testing.expectError(Error.ProtocolViolation, parseFrameHeader(&too_large));
}

test "extended payload lengths must use canonical WebSocket bounds" {
    var noncanonical_16 = [_]u8{ 0x82, 126, 0, 5 };
    try std.testing.expectError(Error.ProtocolViolation, parseFrameHeader(&noncanonical_16));

    var high_bit_64 = [_]u8{ 0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(Error.ProtocolViolation, parseFrameHeader(&high_bit_64));
}
