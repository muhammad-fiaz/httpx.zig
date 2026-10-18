//! Static entropy encoding tables for Brotli.
const std = @import("std");
const bit_writer = @import("../bitstream/bit_writer.zig");

pub const kCodeLengthDepth = [18]u8{
    4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 5, 5, 0,
    4, 4,
};

pub const kCodeLengthBits = [18]u32{
    0,  8, 4, 12, 2, 10, 6,  14,
    1,  9, 5, 13, 3, 15, 31, 0,
    11, 7,
};

/// Command codes 0..447 have depth 9; 448..703 have depth 11 (Kraft sum = 1).
pub const kStaticCommandCodeDepth: [704]u8 = blk: {
    var d: [704]u8 = @splat(9);
    @memset(d[448..704], 11);
    break :blk d;
};

/// Distance codes all have depth 6.
pub const kStaticDistanceCodeDepth: [64]u8 = @splat(6);

/// Canonical 6-bit reversed codes for distances 0..63.
pub const kStaticDistanceCodeBits: [64]u16 = blk: {
    var bits: [64]u16 = undefined;
    for (0..64) |i| {
        bits[i] = @bitReverse(@as(u6, @intCast(i)));
    }
    break :blk bits;
};

/// Zero-run repeat depths for lengths 0..703.
pub const kZeroRepsDepth: [704]u32 = blk: {
    var d: [704]u32 = undefined;
    d[0] = 0;
    d[1] = 4;
    d[2] = 8;
    @memset(d[3..11], 7);
    d[11] = 11;
    @memset(d[12..75], 14);
    @memset(d[75..587], 21);
    @memset(d[587..704], 28);
    break :blk d;
};

/// Non-zero repeat depths for lengths 0..703.
pub const kNonZeroRepsDepth: [704]u32 = blk: {
    var d: [704]u32 = undefined;
    @memset(d[0..4], 6);
    @memset(d[4..20], 12);
    @memset(d[20..84], 18);
    @memset(d[84..340], 24);
    @memset(d[340..704], 30);
    break :blk d;
};

// Embedded static bit patterns for zero reps, non-zero reps, and command codes:
// 1. zero_reps_bits: 704 * 8 bytes = 5632 bytes
// 2. nonzero_reps_bits: 704 * 8 bytes = 5632 bytes
// 3. cmd_bits: 704 * 2 bytes = 1408 bytes
const raw_static align(@alignOf(u64)) = @embedFile("entropy_encode_static.bin").*;

pub const kZeroRepsBits: [704]u64 = @as(*const [704]u64, @ptrCast(raw_static[0..5632])).*;
pub const kNonZeroRepsBits: [704]u64 = @as(*const [704]u64, @ptrCast(raw_static[5632..11264])).*;
pub const kStaticCommandCodeBits: [704]u16 = @as(*const [704]u16, @ptrCast(raw_static[11264..12672])).*;

pub inline fn storeStaticCodeLengthCode(storage_ix: *usize, storage: []u8) void {
    bit_writer.writeBits(40, (@as(u64, 0x0000FF) << 32) | 0x55555554, storage_ix, storage);
}

pub inline fn storeStaticCommandHuffmanTree(storage_ix: *usize, storage: []u8) void {
    bit_writer.writeBits(56, (@as(u64, 0x926244) << 32) | 0x16307003, storage_ix, storage);
    bit_writer.writeBits(3, 0, storage_ix, storage);
}

pub inline fn storeStaticDistanceHuffmanTree(storage_ix: *usize, storage: []u8) void {
    bit_writer.writeBits(28, 0x0369DC03, storage_ix, storage);
}
