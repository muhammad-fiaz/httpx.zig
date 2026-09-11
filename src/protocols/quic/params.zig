//! QUIC transport parameters (RFC 9000 section 18), encoding order and
//! validation rules matching ngtcp2_transport_params.
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
    original_destination_connection_id = 0x00,
    max_idle_timeout = 0x01,
    stateless_reset_token = 0x02,
    max_udp_payload_size = 0x03,
    initial_max_data = 0x04,
    initial_max_stream_data_bidi_local = 0x05,
    initial_max_stream_data_bidi_remote = 0x06,
    initial_max_stream_data_uni = 0x07,
    initial_max_streams_bidi = 0x08,
    initial_max_streams_uni = 0x09,
    ack_delay_exponent = 0x0A,
    max_ack_delay = 0x0B,
    disable_active_migration = 0x0C,
    active_connection_id_limit = 0x0E,
    initial_source_connection_id = 0x0F,
    retry_source_connection_id = 0x10,
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

fn putParam(out: *std.ArrayList(u8), gpa: Allocator, id: u64, value_bytes: []const u8) !void {
    try putV(out, gpa, id);
    try putV(out, gpa, value_bytes.len);
    try out.appendSlice(gpa, value_bytes);
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
        try putParam(out, gpa, @intFromEnum(ParamId.max_idle_timeout), &u64be(p.maxIdleTimeoutMs));
    try putParam(out, gpa, @intFromEnum(ParamId.max_udp_payload_size), &u64be(p.maxUdpPayloadSize));
    if (p.initialMaxData != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_data), &u64be(p.initialMaxData));
    if (p.initialMaxStreamDataBidiLocal != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_stream_data_bidi_local), &u64be(p.initialMaxStreamDataBidiLocal));
    if (p.initialMaxStreamDataBidiRemote != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_stream_data_bidi_remote), &u64be(p.initialMaxStreamDataBidiRemote));
    if (p.initialMaxStreamDataUni != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_stream_data_uni), &u64be(p.initialMaxStreamDataUni));
    if (p.initialMaxStreamsBidi != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_streams_bidi), &u64be(p.initialMaxStreamsBidi));
    if (p.initialMaxStreamsUni != 0)
        try putParam(out, gpa, @intFromEnum(ParamId.initial_max_streams_uni), &u64be(p.initialMaxStreamsUni));
    if (p.ackDelayExponent != 3)
        try putParam(out, gpa, @intFromEnum(ParamId.ack_delay_exponent), &u64be(p.ackDelayExponent));
    if (p.maxAckDelayMs != 25)
        try putParam(out, gpa, @intFromEnum(ParamId.max_ack_delay), &u64be(p.maxAckDelayMs));
    if (p.activeConnectionIdLimit != 2)
        try putParam(out, gpa, @intFromEnum(ParamId.active_connection_id_limit), &u64be(p.activeConnectionIdLimit));
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
    var seen = std.StaticBitSet(17).initEmpty();
    var pos: usize = 0;

    while (pos < data.len) {
        const id_raw = try dv(data, &pos);
        const len_raw = try dv(data, &pos);
        const len = std.math.cast(usize, len_raw) orelse return Error.InvalidParameter;
        if (pos > data.len or len > data.len - pos) return Error.Truncated;

        const id: ParamId = @enumFromInt(id_raw);
        if (@intFromEnum(id) < 17) {
            if (seen.isSet(@intCast(@intFromEnum(id)))) return Error.DuplicateParameter;
            seen.set(@intCast(@intFromEnum(id)));
        }

        switch (id) {
            .original_destination_connection_id, .initial_source_connection_id, .retry_source_connection_id => {
                if (len > 20) return Error.InvalidParameter;
            },
            .stateless_reset_token => {
                if (len != 16) return Error.InvalidParameter;
            },
            .max_idle_timeout, .max_udp_payload_size, .initial_max_data, .initial_max_stream_data_bidi_local, .initial_max_stream_data_bidi_remote, .initial_max_stream_data_uni, .initial_max_streams_bidi, .initial_max_streams_uni, .ack_delay_exponent, .max_ack_delay, .active_connection_id_limit => {
                if (len != 1 and len != 2 and len != 4 and len != 8) return Error.InvalidParameter;
            },
            else => {},
        }

        const value_be: u64 = switch (id) {
            .original_destination_connection_id, .initial_source_connection_id, .retry_source_connection_id, .stateless_reset_token => 0,
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
            .max_idle_timeout => p.maxIdleTimeoutMs = value_be,
            .max_udp_payload_size => {
                if (value_be < 1200) return Error.InvalidParameter;
                p.maxUdpPayloadSize = value_be;
            },
            .initial_max_data => p.initialMaxData = value_be,
            .initial_max_stream_data_bidi_local => p.initialMaxStreamDataBidiLocal = value_be,
            .initial_max_stream_data_bidi_remote => p.initialMaxStreamDataBidiRemote = value_be,
            .initial_max_stream_data_uni => p.initialMaxStreamDataUni = value_be,
            .initial_max_streams_bidi => p.initialMaxStreamsBidi = value_be,
            .initial_max_streams_uni => p.initialMaxStreamsUni = value_be,
            .ack_delay_exponent => {
                if (value_be > 20) return Error.InvalidParameter;
                p.ackDelayExponent = value_be;
            },
            .max_ack_delay => {
                if (value_be >= 1 << 14) return Error.InvalidParameter;
                p.maxAckDelayMs = value_be;
            },
            .active_connection_id_limit => {
                if (value_be < 2) return Error.InvalidParameter;
                p.activeConnectionIdLimit = value_be;
            },
            else => {}, // unknown / CID-carrying handled by connection
        }
        pos += len;
    }
    return p;
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
        const bad = try mk.enc(@intFromEnum(ParamId.max_udp_payload_size), 1199);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@intFromEnum(ParamId.ack_delay_exponent), 21);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@intFromEnum(ParamId.max_ack_delay), 1 << 14);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
    {
        const bad = try mk.enc(@intFromEnum(ParamId.active_connection_id_limit), 1);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(Error.InvalidParameter, decode(bad));
    }
}
