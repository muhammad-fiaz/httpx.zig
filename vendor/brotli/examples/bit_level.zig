//! Bit-level view of Brotli streams: LSB-first bit packing, the unit
//! every header field and Huffman code is built from.

const std = @import("std");

/// Appends `count` low bits of `value` to an LSB-first accumulator.
fn appendBits(acc: *u64, n_bits: *u6, value: u64, count: u6) void {
    acc.* |= (value & ((@as(u64, 1) << count) - 1)) << n_bits.*;
    n_bits.* += count;
}

pub fn main() void {
    // Pack 3-bit field 0b101, then 5-bit field 0b11011 -> 0b11011_101 LSB-first.
    var acc: u64 = 0;
    var n: u6 = 0;
    appendBits(&acc, &n, 0b101, 3);
    appendBits(&acc, &n, 0b11011, 5);
    std.debug.print("packed {d} bits -> 0x{X:0>2}\n", .{ n, acc });

    // Read them back in the same order a decoder would.
    const f1: u64 = acc & 7;
    const f2: u64 = (acc >> 3) & 31;
    std.debug.print("field1=0b{b:0>3} field2=0b{b:0>5}\n", .{ f1, f2 });

    // Huffman codes are stored most-significant-bit first within each
    // code word even though the stream itself flows LSB-first.
    var reversed: u6 = 0;
    const code: u6 = 0b110;
    for (0..3) |i| {
        if ((code >> @intCast(i)) & 1 != 0) reversed |= @as(u6, 1) << @intCast(2 - i);
    }
    std.debug.print("code 0b110 reversed for stream order: 0b{b:0>3}\n", .{reversed});
}
