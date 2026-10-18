//! Fast log2 helpers; the 256-entry lookup table is generated at compile time.

const std = @import("std");

pub const LOG2_TABLE_SIZE = 256;

/// log2 of [0, 255], generated at comptime.
pub const kLog2Table: [LOG2_TABLE_SIZE]f64 = blk: {
    var t: [LOG2_TABLE_SIZE]f64 = undefined;
    t[0] = 0.0;
    for (1..LOG2_TABLE_SIZE) |i| {
        t[i] = std.math.log2(@as(f64, @floatFromInt(i)));
    }
    break :blk t;
};

/// Floor of log2 for non-zero values.
pub inline fn log2FloorNonZero(n: usize) u32 {
    return std.math.log2_int(usize, n);
}

pub inline fn log2FloorNonZero64(n: u64) u32 {
    return std.math.log2_int(u64, n);
}

/// Faster logarithm for small integers, with the property log2(0) == 0.
pub inline fn fastLog2(v: usize) f64 {
    if (v < LOG2_TABLE_SIZE) {
        return kLog2Table[v];
    }
    return std.math.log2(@as(f64, @floatFromInt(v)));
}

test "fastLog2 matches table bounds" {
    try std.testing.expectEqual(@as(f64, 0.0), fastLog2(0));
    try std.testing.expectEqual(@as(f64, 1.0), fastLog2(2));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), fastLog2(128), 1e-9);
}

test "log2FloorNonZero" {
    try std.testing.expectEqual(@as(u32, 0), log2FloorNonZero(1));
    try std.testing.expectEqual(@as(u32, 1), log2FloorNonZero(3));
    try std.testing.expectEqual(@as(u32, 4), log2FloorNonZero(31));
}
