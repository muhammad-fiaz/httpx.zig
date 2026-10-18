//! LSB-first bit reader for the Brotli decoder.
//!
//! Uses a 64-bit accumulator with fast unaligned little-endian reads when
//! enough contiguous input remains, falling back to byte-at-a-time pulls
//! otherwise. Both paths are strictly bounds-checked.

const std = @import("std");

pub const BitReader = struct {
    val: u64 = 0, // pre-fetched bits; only low bit_pos bits are valid
    bit_pos: u32 = 0, // number of valid bits in val (0..64)
    input: []const u8 = &.{}, // current input buffer
    pos: usize = 0, // byte offset of next unread byte within input

    pub fn init(input: []const u8) BitReader {
        return .{ .input = input, .pos = 0 };
    }

    pub fn setInput(br: *BitReader, input: []const u8) void {
        br.input = input;
        br.pos = 0;
    }

    pub fn reset(br: *BitReader, input: []const u8) void {
        br.* = init(input);
    }

    /// Bytes left in the current input window. Saturates at zero so that a
    /// cursor parked past the end of a short window can never underflow.
    pub inline fn availIn(br: *const BitReader) usize {
        return br.input.len -| br.pos;
    }

    /// Number of bits currently held in the accumulator.
    pub inline fn availableBits(br: *const BitReader) u32 {
        return br.bit_pos;
    }

    /// Bytes still readable, including whole bytes buffered in the accumulator
    /// (capped).
    pub fn remainingBytes(br: *const BitReader) usize {
        const cap: usize = @as(usize, 1) << 30;
        return @min(br.availIn() + (br.bit_pos >> 3), cap);
    }

    /// Pulls one byte into the accumulator; false when out of input or full.
    pub inline fn pullByte(br: *BitReader) bool {
        if (br.availIn() == 0 or br.bit_pos >= 64) return false;
        br.val |= @as(u64, br.input[br.pos]) << @intCast(br.bit_pos);
        br.pos += 1;
        br.bit_pos += 8;
        return true;
    }

    fn fillBytes(br: *BitReader) void {
        // Fill the accumulator with whole bytes while there is room.
        if (br.availIn() >= 8 and br.bit_pos == 0) {
            br.val = std.mem.readInt(u64, br.input[br.pos..][0..8], .little);
            br.pos += 8;
            br.bit_pos = 64;
            return;
        }
        if (br.bit_pos <= 32 and br.availIn() >= 4) {
            const next_u32 = std.mem.readInt(u32, br.input[br.pos..][0..4], .little);
            br.val |= @as(u64, next_u32) << @intCast(br.bit_pos);
            br.pos += 4;
            br.bit_pos += 32;
        }
        while (br.bit_pos <= 56 and br.availIn() > 0) {
            br.val |= @as(u64, br.input[br.pos]) << @intCast(br.bit_pos);
            br.pos += 1;
            br.bit_pos += 8;
        }
    }

    /// Ensures the accumulator holds at least `n_bits` valid bits
    /// (`n_bits` <= 32). False when the input ends before that.
    pub fn ensureBits(br: *BitReader, n_bits: u32) bool {
        std.debug.assert(n_bits <= 32);
        if (br.bit_pos < n_bits) {
            br.fillBytes();
            while (br.bit_pos < n_bits) {
                if (!br.pullByte()) return false;
            }
        }
        return true;
    }

    /// Peeks the lowest `n_bits` (<= 63); they must be present.
    pub inline fn getBits(br: *const BitReader, n_bits: u6) u64 {
        return br.val & ((@as(u64, 1) << n_bits) -% 1);
    }

    pub inline fn getBits32(br: *const BitReader, n_bits: u6) u64 {
        if (n_bits == 0) return 0;
        if (n_bits >= 64) return br.val;
        return br.getBits(n_bits);
    }

    /// Consumes `n_bits`; they must be present.
    pub inline fn dropBits(br: *BitReader, n_bits: u32) void {
        std.debug.assert(n_bits <= br.bit_pos);
        br.val >>= @intCast(n_bits);
        br.bit_pos -= n_bits;
    }

    /// Reads and consumes up to 24 bits; null on end of input.
    pub fn readBits24(br: *BitReader, n_bits: u32) ?u64 {
        std.debug.assert(n_bits <= 24);
        if (!br.ensureBits(n_bits)) return null;
        const v = br.getBits32(@intCast(n_bits));
        br.dropBits(n_bits);
        return v;
    }

    /// Reads and consumes up to 32 bits (large-window streams); null on EOF.
    pub fn readBits32(br: *BitReader, n_bits: u32) ?u64 {
        std.debug.assert(n_bits <= 32);
        if (!br.ensureBits(n_bits)) return null;
        const v = br.getBits32(@intCast(n_bits));
        br.dropBits(n_bits);
        return v;
    }

    /// Safe variant writing through a pointer; false on end of input.
    /// `n_bits == 0` yields 0 without consuming anything.
    pub fn safeReadBits(br: *BitReader, n_bits: u32, val: *u64) bool {
        if (!br.ensureBits(n_bits)) return false;
        val.* = br.getBits32(@intCast(n_bits));
        br.dropBits(n_bits);
        return true;
    }

    /// Moves to the next byte boundary; false if skipped bits were non-zero
    /// (which indicates stream corruption per the format's padding rules).
    pub fn jumpToByteBoundary(br: *BitReader) bool {
        const pad_bits_count: u3 = @intCast(br.bit_pos & 7);
        var pad_bits: u64 = 0;
        if (pad_bits_count != 0) {
            pad_bits = br.getBits(pad_bits_count);
            br.dropBits(pad_bits_count);
        }
        br.normalize();
        return pad_bits == 0;
    }

    /// Masks off any bits above bit_pos (removes "spectre" bits after skips).
    pub fn normalize(br: *BitReader) void {
        if (br.bit_pos < 64) {
            br.val &= (@as(u64, 1) << @intCast(br.bit_pos)) - 1;
        }
    }

    /// Returns unconsumed whole accumulator bytes back to the input so that
    /// `availIn` reports exactly the input not yet reflected in decoded data,
    /// keeping fewer than 8 bits in the accumulator.
    pub fn unload(br: *BitReader) void {
        // Whole bytes still sitting in the accumulator are handed back to the
        // input window. Bits that were buffered before the window was last
        // re-pointed have no byte to go back to, so the number of returned
        // bytes is clamped to what the current window can actually give.
        const unused_bytes: u32 = br.bit_pos >> 3;
        const returnable: u32 = @intCast(@min(br.pos, @as(usize, unused_bytes)));
        if (returnable != 0) {
            br.pos -= returnable;
            br.bit_pos -= returnable * 8;
        }
        br.normalize();
    }
};

test "bit reader basic reads" {
    var br = BitReader.init(&.{ 0b10101010, 0b11001100 });
    try std.testing.expectEqual(@as(u64, 0b010), br.readBits24(3).?);
    try std.testing.expectEqual(@as(u64, 0b10101), br.readBits24(5).?);
    try std.testing.expectEqual(@as(u64, 0b11001100), br.readBits24(8).?);
    try std.testing.expectEqual(@as(?u64, null), br.readBits24(1));
}

test "bit reader matches a naive bit walk" {
    var data: [40]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    rng.random().bytes(&data);
    var br = BitReader.init(&data);
    var src_bit: usize = 0;
    while (src_bit + 13 <= 320) : (src_bit += 13) {
        const v = br.readBits24(13).?;
        var want: u64 = 0;
        var k: usize = 0;
        while (k < 13) : (k += 1) {
            const bitpos = src_bit + k;
            const bit = (data[bitpos / 8] >> @intCast(bitpos % 8)) & 1;
            want |= @as(u64, bit) << @intCast(k);
        }
        try std.testing.expectEqual(want, v);
    }
    try std.testing.expectEqual(@as(?u64, null), br.readBits24(13));
}

test "unload returns whole bytes" {
    var br = BitReader.init(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    _ = br.readBits24(3).?;
    br.unload();
    // Byte 0 is partially consumed (5 bits left in the accumulator); the
    // other 7 bytes are returned to the input.
    try std.testing.expectEqual(@as(usize, 7), br.availIn());
    try std.testing.expectEqual(@as(u32, 5), br.availableBits());
    try std.testing.expectEqual(@as(u64, 1 >> 3), br.getBits(5));
}

test "unload with interleaved refills" {
    var data: [64]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var br = BitReader.init(&data);
    _ = br.readBits24(13).?; // forces a refill of 8 + consume 13
    br.unload();
    // Stream position must be preserved exactly: 8*(pos) - bit_pos bits
    // consumed.
    const consumed_bits = 8 * (data.len - br.availIn()) - br.availableBits();
    try std.testing.expectEqual(@as(usize, 13), consumed_bits);
}

test "jumpToByteBoundary padding detection" {
    var br = BitReader.init(&.{ 0xFF, 0xFF });
    _ = br.readBits24(4).?;
    try std.testing.expect(!br.jumpToByteBoundary()); // pad bits 1111 != 0

    var br2 = BitReader.init(&.{ 0x01, 0x00 });
    _ = br2.readBits24(4).?; // consumes 0001; remaining pad bits are 0
    try std.testing.expect(br2.jumpToByteBoundary());
}

test "short input safe reads" {
    var br = BitReader.init(&.{0xAB});
    var out: u64 = 0;
    try std.testing.expect(br.safeReadBits(4, &out));
    try std.testing.expectEqual(@as(u64, 0xB), out);
    try std.testing.expect(!br.safeReadBits(8, &out)); // only 4 bits left
}

test "unload when all accumulator bits are whole bytes" {
    const data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    var br = BitReader.init(&data);
    _ = br.ensureBits(32);
    br.unload();
    try std.testing.expectEqual(@as(usize, 0), br.pos);
    try std.testing.expectEqual(@as(u32, 0), br.bit_pos);
    try std.testing.expectEqual(@as(u64, 0), br.val);
}
