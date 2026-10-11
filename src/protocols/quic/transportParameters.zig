//! QUIC transport parameters (RFC 9000 section 18), encoding order and
//! validation rules matching ngtcp2TransportParams.
//!
//! Wire: sequence of {varint id, varint length, opaque value}. Absent
//! numeric parameters take their defaults; presence-sensitive CIDs are
//! handled explicitly by the connection layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const varint = @import("varint.zig");

pub const Error = error{
    Truncated,
    InvalidParameter,
    DuplicateParameter,
    OutOfMemory,
    BufferTooSmall,
};

pub const ParamId = enum(u64) {
    originalDestinationConnectionId = 0x00,
    maxIdleTimeout = 0x01,
    statelessResetToken = 0x02,
    maxUdpPayloadSize = 0x03,
    initialMaxData = 0x04,
    initialMaxStreamDataBidiLocal = 0x05,
    initialMaxStreamDataBidiRemote = 0x06,
    initialMaxStreamDataUni = 0x07,
    initialMaxStreamsBidi = 0x08,
    initialMaxStreamsUni = 0x09,
    ackDelayExponent = 0x0A,
    maxAckDelay = 0x0B,
    disableActiveMigration = 0x0C,
    activeConnectionIdLimit = 0x0E,
    initialSourceConnectionId = 0x0F,
    retrySourceConnectionId = 0x10,
    _,
};

/// Numeric parameter set with RFC defaults for absent entries.
pub const Params = struct {
    maxIdleTimeoutMs: u64 = 0, // 0 = disabled
    maxUdpPayloadSize: u64 = 65527,
    initialMaxData: u64 = 0,
    initialMaxStreamDataBidiLocal: u64 = 0,
    initialMaxStreamDataBidiRemote: u64 = 0,
    initialMaxStreamDataUni: u64 = 0,
    initialMaxStreamsBidi: u64 = 0,
    initialMaxStreamsUni: u64 = 0,
    ackDelayExponent: u64 = 3,
    maxAckDelayMs: u64 = 25,
    activeConnectionIdLimit: u64 = 2,
};

fn putParam(out: *std.ArrayList(u8), gpa: Allocator, id: u64, valueBytes: []const u8) !void {
    try putV(out, gpa, id);
    try putV(out, gpa, valueBytes.len);
    try out.appendSlice(gpa, valueBytes);
}

inline fn putV(out: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var tmp: [8]u8 = undefined;
    const n = varint.encode(tmp[0..], v) catch return error.BufferTooSmall;
    try out.appendSlice(gpa, tmp[0..n]);
}

fn u64be(v: u64) [8]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u64, v));
}

/// Encodes the numeric parameter set (CIDs appended separately by the
/// connection layer since they carry raw bytes).
pub fn encode(out: *std.ArrayList(u8), gpa: Allocator, p: Params) !void {
    if (p.maxUdpPayloadSize < 1200 or p.maxUdpPayloadSize > 65527) return Error.InvalidParameter;
    if (p.ackDelayExponent > 20 or p.maxAckDelayMs >= (1 << 14)) return Error.InvalidParameter;
    if (p.activeConnectionIdLimit < 2) return Error.InvalidParameter;
    // Only emit non-default values where the spec allows omission.
    if (p.maxIdleTimeoutMs != 0)
        try putParam(out, gpa, @backingInt(ParamId.maxIdleTimeout), &u64be(p.maxIdleTimeoutMs));
    try putParam(out, gpa, @backingInt(ParamId.maxUdpPayloadSize), &u64be(p.maxUdpPayloadSize));
    if (p.initialMaxData != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxData), &u64be(p.initialMaxData));
    if (p.initialMaxStreamDataBidiLocal != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxStreamDataBidiLocal), &u64be(p.initialMaxStreamDataBidiLocal));
    if (p.initialMaxStreamDataBidiRemote != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxStreamDataBidiRemote), &u64be(p.initialMaxStreamDataBidiRemote));
    if (p.initialMaxStreamDataUni != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxStreamDataUni), &u64be(p.initialMaxStreamDataUni));
    if (p.initialMaxStreamsBidi != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxStreamsBidi), &u64be(p.initialMaxStreamsBidi));
    if (p.initialMaxStreamsUni != 0)
        try putParam(out, gpa, @backingInt(ParamId.initialMaxStreamsUni), &u64be(p.initialMaxStreamsUni));
    if (p.ackDelayExponent != 3)
        try putParam(out, gpa, @backingInt(ParamId.ackDelayExponent), &u64be(p.ackDelayExponent));
    if (p.maxAckDelayMs != 25)
        try putParam(out, gpa, @backingInt(ParamId.maxAckDelay), &u64be(p.maxAckDelayMs));
    if (p.activeConnectionIdLimit != 2)
        try putParam(out, gpa, @backingInt(ParamId.activeConnectionIdLimit), &u64be(p.activeConnectionIdLimit));
}

fn dv(data: []const u8, pos: *usize) Error!u64 {
    return varint.decode(data, pos) catch |e| switch (e) {
        else => Error.Truncated,
    };
}

/// Decodes and validates the numeric parameter set. Unknown IDs ignored;
/// duplicate known IDs rejected.
pub fn decode(data: []const u8) Error!Params {
    var p: Params = .{};
    var seen = std.StaticBitSet(17).empty;
    var pos: usize = 0;

    while (pos < data.len) {
        const idRaw = try dv(data, &pos);
        const lenRaw = try dv(data, &pos);
        const len = std.math.cast(usize, lenRaw) orelse return Error.InvalidParameter;
        if (pos > data.len or len > data.len - pos) return Error.Truncated;

        const id: ParamId = @fromBackingInt(@intCast(idRaw));
        if (@backingInt(id) < 17) {
            if (seen.isSet(@intCast(@backingInt(id)))) return Error.DuplicateParameter;
            seen.set(@intCast(@backingInt(id)));
        }

        switch (id) {
            .originalDestinationConnectionId, .initialSourceConnectionId, .retrySourceConnectionId => {
                if (len > 20) return Error.InvalidParameter;
            },
            .statelessResetToken => {
                if (len != 16) return Error.InvalidParameter;
            },
            .maxIdleTimeout, .maxUdpPayloadSize, .initialMaxData, .initialMaxStreamDataBidiLocal, .initialMaxStreamDataBidiRemote, .initialMaxStreamDataUni, .initialMaxStreamsBidi, .initialMaxStreamsUni, .ackDelayExponent, .maxAckDelay, .activeConnectionIdLimit => {
                if (len != 1 and len != 2 and len != 4 and len != 8) return Error.InvalidParameter;
            },
            else => {},
        }

        const valueBe: u64 = switch (id) {
            .originalDestinationConnectionId, .initialSourceConnectionId, .retrySourceConnectionId, .statelessResetToken => 0,
            else => switch (len) {
                0 => 0,
                1 => data[pos],
                2 => std.mem.readInt(u16, data[pos..][0..2], .big),
                4 => std.mem.readInt(u32, data[pos..][0..4], .big),
                8 => std.mem.readInt(u64, data[pos..][0..8], .big),
                else => return Error.InvalidParameter, // numeric params are pow2-len BE
            },
        };

        switch (id) {
            .maxIdleTimeout => p.maxIdleTimeoutMs = valueBe,
            .maxUdpPayloadSize => {
                if (valueBe < 1200) return Error.InvalidParameter;
                p.maxUdpPayloadSize = valueBe;
            },
            .initialMaxData => p.initialMaxData = valueBe,
            .initialMaxStreamDataBidiLocal => p.initialMaxStreamDataBidiLocal = valueBe,
            .initialMaxStreamDataBidiRemote => p.initialMaxStreamDataBidiRemote = valueBe,
            .initialMaxStreamDataUni => p.initialMaxStreamDataUni = valueBe,
            .initialMaxStreamsBidi => p.initialMaxStreamsBidi = valueBe,
            .initialMaxStreamsUni => p.initialMaxStreamsUni = valueBe,
            .ackDelayExponent => {
                if (valueBe > 20) return Error.InvalidParameter;
                p.ackDelayExponent = valueBe;
            },
            .maxAckDelay => {
                if (valueBe >= 1 << 14) return Error.InvalidParameter;
                p.maxAckDelayMs = valueBe;
            },
            .activeConnectionIdLimit => {
                if (valueBe < 2) return Error.InvalidParameter;
                p.activeConnectionIdLimit = valueBe;
            },
            else => {}, // unknown / CID-carrying handled by connection
        }
        pos += len;
    }
    return p;
}

/// Byte-carrying transport parameters (connection IDs and tokens),
/// borrowed from the block. Absent entries are null.
pub const CidParams = struct {
    originalDestinationConnectionId: ?[]const u8 = null,
    initialSourceConnectionId: ?[]const u8 = null,
    retrySourceConnectionId: ?[]const u8 = null,
    statelessResetToken: ?[]const u8 = null,
};

/// Extracts the byte-carrying parameters, validating lengths and
/// duplicates. Unknown IDs are skipped; numeric validation stays in
/// `decode` (call both on the same block).
pub fn parseCidParams(data: []const u8) Error!CidParams {
    var out: CidParams = .{};
    var seenOdcid = false;
    var seenIscid = false;
    var seenRscid = false;
    var seenSrt = false;
    var pos: usize = 0;
    while (pos < data.len) {
        const id = try dv(data, &pos);
        const lenRaw = try dv(data, &pos);
        const len = std.math.cast(usize, lenRaw) orelse return Error.InvalidParameter;
        if (pos > data.len or len > data.len - pos) return Error.Truncated;
        const value = data[pos..][0..len];
        pos += len;
        switch (id) {
            0x00 => {
                if (seenOdcid or len > 20) return Error.InvalidParameter;
                seenOdcid = true;
                out.originalDestinationConnectionId = value;
            },
            0x0F => {
                if (seenIscid or len > 20) return Error.InvalidParameter;
                seenIscid = true;
                out.initialSourceConnectionId = value;
            },
            0x10 => {
                if (seenRscid or len > 20) return Error.InvalidParameter;
                seenRscid = true;
                out.retrySourceConnectionId = value;
            },
            0x02 => {
                if (seenSrt or len != 16) return Error.InvalidParameter;
                seenSrt = true;
                out.statelessResetToken = value;
            },
            else => {},
        }
    }
    return out;
}

// Tests

test "encode/decode roundtrip preserves values" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);

    try encode(&list, std.testing.allocator, .{
        .maxIdleTimeoutMs = 30_000,
        .initialMaxData = 1 << 20,
        .initialMaxStreamsBidi = 128,
        .ackDelayExponent = 5,
        .maxAckDelayMs = 40,
        .activeConnectionIdLimit = 8,
    });

    const got = try decode(list.items);
    try std.testing.expectEqual(@as(u64, 30_000), got.maxIdleTimeoutMs);
    try std.testing.expectEqual(@as(u64, 1 << 20), got.initialMaxData);
    try std.testing.expectEqual(@as(u64, 128), got.initialMaxStreamsBidi);
    try std.testing.expectEqual(@as(u64, 5), got.ackDelayExponent);
    try std.testing.expectEqual(@as(u64, 40), got.maxAckDelayMs);
    try std.testing.expectEqual(@as(u64, 8), got.activeConnectionIdLimit);
}

test "empty encoding yields all defaults" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{});
    const got = try decode(list.items);
    try std.testing.expectEqual(@as(u64, 65527), got.maxUdpPayloadSize);
    try std.testing.expectEqual(@as(u64, 3), got.ackDelayExponent);
    try std.testing.expectEqual(@as(u64, 25), got.maxAckDelayMs);
    try std.testing.expectEqual(@as(u64, 2), got.activeConnectionIdLimit);
}

test "encoder rejects invalid local transport parameters" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try std.testing.expectError(Error.InvalidParameter, encode(&list, std.testing.allocator, .{ .maxUdpPayloadSize = 1199 }));
    try std.testing.expectError(Error.InvalidParameter, encode(&list, std.testing.allocator, .{ .ackDelayExponent = 21 }));
    try std.testing.expectError(Error.InvalidParameter, encode(&list, std.testing.allocator, .{ .activeConnectionIdLimit = 1 }));
}

test "validation bounds reject hostile values" {
    const mk = struct {
        fn enc(id: u64, v: u64) ![]u8 {
            var list = std.ArrayList(u8).empty;
            errdefer list.deinit(std.testing.allocator);
            var vb: [8]u8 = undefined;
            std.mem.writeInt(u64, &vb, v, .big);
            try putParam(&list, std.testing.allocator, id, vb[0..]);
            return list.toOwnedSlice(std.testing.allocator);
        }
    };
    {
        const bad = try mk.enc(@backingInt(ParamId.maxUdpPayloadSize), 1199);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@backingInt(ParamId.ackDelayExponent), 21);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@backingInt(ParamId.maxAckDelay), 1 << 14);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@backingInt(ParamId.activeConnectionIdLimit), 1);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
}
