//! Literal context modeling per RFC 7932 section 7.1.

const std = @import("std");
const tables = @import("context_table.zig");

pub const ContextType = enum(u2) {
    lsb6 = 0,
    msb6 = 1,
    utf8 = 2,
    signed = 3,

    pub fn fromInt(v: u32) ContextType {
        return @fromBackingInt(@intCast(@as(u2, @intCast(v & 3))));
    }
};

/// Size (in bytes) of one mode's half of the context lookup table.
const HALF = 256;

/// Returns the combined 512-entry LUT for `mode`: entries [0..255] map the
/// last byte and [256..511] map the second-last byte.
pub inline fn contextLut(mode: ContextType) *const [512]u8 {
    const base: usize = @as(usize, @backingInt(mode)) << 9;
    return tables.table[base..][0..512];
}

/// Computes the literal context id from the previous two bytes using the
/// combined 512-entry LUT.
pub inline fn contextId(p1: u8, p2: u8, mode: ContextType) u8 {
    const base: usize = @as(usize, @backingInt(mode)) << 9;
    return tables.table[base + p1] | tables.table[base + 256 + p2];
}

test "context ids are within range" {
    var p1: u16 = 0;
    while (p1 < 256) : (p1 += 1) {
        var p2: u16 = 0;
        while (p2 < 256) : (p2 += 1) {
            inline for (std.enums.values(ContextType)) |mode| {
                const id = contextId(@intCast(p1), @intCast(p2), mode);
                try std.testing.expect(id < 64);
            }
        }
    }
}
