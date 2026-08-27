//! Prefixed variable-length integers (RFC 7541 §5.1 / RFC 9204 §4.1.1).
//!
//! One authoritative implementation shared by HPACK and QPACK. The wire
//! format: an N-bit prefix in the first byte carries the opcode-specific
//! bits in its high positions; the low N bits encode the integer when it
//! fits below the prefix maximum, otherwise the maximum is emitted and
//! the remainder follows as base-128 digits with continuation bits.

const std = @import("std");

pub const Error = error{
    BufferTooSmall,
    Truncated,
    /// Integer exceeded the configured byte budget or would overflow u64.
    IntegerOverflow,
};

/// Maximum bytes a decoded integer may consume (DoS bound; matches the
/// 62-bit QUIC-style ceiling used by nghttp2/nghttp3).
pub const max_decode_bytes: usize = 10;

/// Encodes `value` into `buf` using the low `prefix_bits` of buf[0].
/// `first_byte_high` bits are OR-ed into the high positions of buf[0]
/// (opcode bits); callers pass 0 when none apply. Returns bytes written.
pub fn encode(buf: []u8, prefix_bits: u3, first_byte_high: u8, value: u64) Error!usize {
    std.debug.assert(prefix_bits >= 1 and prefix_bits <= 7);
    if (buf.len < 1) return Error.BufferTooSmall;

    const max_prefix: u64 = (@as(u64, 1) << prefix_bits) - 1;
    const high_mask: u8 = @intCast((@as(u16, 0xFF) << prefix_bits) & 0xFF);

    if (value < max_prefix) {
        buf[0] = (first_byte_high & high_mask) | @as(u8, @intCast(value));
        return 1;
    }

    buf[0] = (first_byte_high & high_mask) | @as(u8, @intCast(max_prefix));
    var remaining = value - max_prefix;
    var pos: usize = 1;
    while (remaining >= 128) {
        if (pos >= buf.len) return Error.BufferTooSmall;
        buf[pos] = @as(u8, @intCast(remaining % 128)) | 0x80;
        remaining /= 128;
        pos += 1;
    }
    if (pos >= buf.len) return Error.BufferTooSmall;
    buf[pos] = @intCast(remaining);
    return pos + 1;
}

/// Decodes an integer whose prefix occupies `prefix_bits` of data[offset.*].
/// The high bits of the first byte are ignored (caller dispatches opcodes
/// on them beforehand). `offset` advances past the integer.
pub fn decode(data: []const u8, offset: *usize, prefix_bits: u3) Error!u64 {
    if (offset.* >= data.len) return Error.Truncated;
    const max_prefix: u64 = (@as(u64, 1) << prefix_bits) - 1;

    var value: u64 = data[offset.*] & @as(u8, @intCast(max_prefix));
    offset.* += 1;
    if (value < max_prefix) return value;

    var shift: u6 = 0;
    var used: usize = 1;
    while (true) {
        if (offset.* >= data.len) return Error.Truncated;
        if (used > max_decode_bytes) return Error.IntegerOverflow;
        const byte = data[offset.*];
        offset.* += 1;
        used += 1;
        if (shift >= 57 and (byte & 0x7F) > 1) return Error.IntegerOverflow;
        const contribution = @as(u64, byte & 0x7F) << shift;
        value = std.math.add(u64, value, contribution) catch return Error.IntegerOverflow;
        if (byte & 0x80 == 0) return value;
        if (shift >= 63) return Error.IntegerOverflow;
        shift += 7;
    }
}

/// Number of bytes `encode` will produce (for sizing buffers).
pub fn encodedLen(prefix_bits: u3, value: u64) usize {
    const max_prefix: u64 = (@as(u64, 1) << prefix_bits) - 1;
    if (value < max_prefix) return 1;
    var remaining = value - max_prefix;
    var digits: usize = 1;
    while (remaining >= 128) : (digits += 1) remaining /= 128;
    return 1 + digits;
}

test "roundtrip across prefix widths and magnitudes" {
    var buf: [16]u8 = undefined;
    const values = [_]u64{
        0,             1,                   61,        62,
        63,            127,                 128,       129,
        255,           256,                 4095,      4096,
        65535,         65536,               1_000_000, 4_294_967_295,
        4_294_967_296, 4611686018427387903,
    };
    for ([_]u3{ 3, 4, 5, 6, 7 }) |pfx| {
        for (values) |v| {
            @memset(&buf, 0xAA);
            const n = try encode(&buf, pfx, 0, v);
            try std.testing.expectEqual(encodedLen(pfx, v), n);
            var off: usize = 0;
            const back = try decode(buf[0..n], &off, pfx);
            try std.testing.expectEqual(v, back);
            try std.testing.expectEqual(n, off);
        }
    }
}

test "preserves high opcode bits in first byte" {
    var buf: [8]u8 = undefined;
    // 7-bit prefix, opcode 0x80 (indexed field line marker)
    const n = try encode(&buf, 7, 0x80, 5);
    try std.testing.expectEqual(@as(u8, 0x85), buf[0]);
    var off: usize = 0;
    try std.testing.expectEqual(@as(u64, 5), try decode(buf[0..n], &off, 7));
}

test "rejects truncated and oversized input" {
    const long_val: u64 = std.math.maxInt(u64) / 2;
    var buf: [16]u8 = undefined;
    const n = try encode(&buf, 7, 0, long_val);
    // Every truncation must fail cleanly, never misparse.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var off: usize = 0;
        try std.testing.expectError(Error.Truncated, decode(buf[0..i], &off, 7));
    }
    var off2: usize = 0;
    _ = try decode(buf[0..n], &off2, 7);
    try std.testing.expectEqual(@as(usize, n), off2);
}

test "overflow guard rejects absurd continuation chains" {
    // 11 continuation bytes each claiming maximum weight -> overflow.
    const evil = [_]u8{0xFF} ** 11 ++ [_]u8{0x00};
    var off: usize = 0;
    try std.testing.expectError(Error.IntegerOverflow, decode(&evil, &off, 7));
}
