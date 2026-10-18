//! Writes bits into a byte array, LSB-first within each byte.

const std = @import("std");

/// Writes `n_bits` (<= 56) of the low bits of `bits` at bit position `*pos`.
pub inline fn writeBits(n_bits: u6, bits: u64, pos: *usize, array: []u8) void {
    if (n_bits == 0) return;
    std.debug.assert(if (n_bits == 64) true else (bits >> @intCast(n_bits)) == 0);
    const byte_pos = pos.* >> 3;
    const p = array[byte_pos..];
    if (p.len >= 8) {
        var v: u64 = p[0];
        v |= bits << @intCast(pos.* & 7);
        std.mem.writeInt(u64, p[0..8], v, .little);
        pos.* += n_bits;
    } else {
        const bits_reserved: u3 = @intCast(pos.* & 7);
        var current_bits = bits << bits_reserved;
        p[0] |= @truncate(current_bits);
        var written_bytes: usize = 1;
        var bits_left: usize = n_bits + bits_reserved;
        while (bits_left >= 9 and written_bytes < p.len) {
            current_bits >>= 8;
            p[written_bytes] = @truncate(current_bits);
            written_bytes += 1;
            bits_left -= 8;
        }
        if (written_bytes < p.len) {
            p[written_bytes] = 0;
        }
        pos.* += n_bits;
    }
}

/// Zeroes the byte containing bit position `pos`; `pos` must be byte-aligned.
pub inline fn writeBitsPrepareStorage(pos: usize, array: []u8) void {
    std.debug.assert(pos & 7 == 0);
    array[pos >> 3] = 0;
}

/// Rounds the bit position up to the next byte boundary.
pub inline fn jumpToByteBoundary(pos: *usize, storage: []u8) void {
    pos.* = (pos.* + 7) & ~@as(usize, 7);
    if ((pos.* >> 3) < storage.len) storage[pos.* >> 3] = 0;
}

test "writeBits packs LSB first" {
    var buf: [16]u8 = @splat(0);
    var pos: usize = 0;
    // Write 3 bits = 0b101, then 5 bits = 0b11010 -> byte0 = 0b11010101.
    writeBits(3, 0b101, &pos, &buf);
    try std.testing.expectEqual(@as(usize, 3), pos);
    writeBits(5, 0b11010, &pos, &buf);
    try std.testing.expectEqual(@as(u8, 0b11010101), buf[0]);
}

test "writeBits spans bytes" {
    var buf: [16]u8 = @splat(0);
    var pos: usize = 5;
    writeBits(9, 0x1AB, &pos, &buf); // 9 bits starting at offset 5.
    try std.testing.expectEqual(@as(usize, 14), pos);
    const lo: u16 = @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
    try std.testing.expectEqual(@as(u16, 0x1AB << 5), lo & 0xFFFF);
}

test "jumpToByteBoundary" {
    var buf: [4]u8 = @splat(0xFF);
    var pos: usize = 11;
    jumpToByteBoundary(&pos, &buf);
    try std.testing.expectEqual(@as(usize, 16), pos);
}
