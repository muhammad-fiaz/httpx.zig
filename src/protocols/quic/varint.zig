// QUIC variable-length integer encoding (RFC 9000 section 16).
// 2-bit length prefix: 00=1byte(6bit) 01=2bytes(14bit) 10=4bytes(30bit) 11=8bytes(62bit)

const std = @import("std");

pub const Error = error{ BufferTooSmall, Truncated, TooLarge };

pub fn encode(buf: []u8, value: u64) Error!usize {
    if (value <= 0x3F) {
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    } else if (value <= 0x3FFF) {
        if (buf.len < 2) return Error.BufferTooSmall;
        buf[0] = @intCast((value >> 8) | 0x40);
        buf[1] = @intCast(value & 0xFF);
        return 2;
    } else if (value <= 0x3FFFFFFF) {
        if (buf.len < 4) return Error.BufferTooSmall;
        buf[0] = @intCast((value >> 24) | 0x80);
        buf[1] = @intCast((value >> 16) & 0xFF);
        buf[2] = @intCast((value >> 8) & 0xFF);
        buf[3] = @intCast(value & 0xFF);
        return 4;
    } else if (value <= 0x3FFFFFFFFFFFFFFF) {
        if (buf.len < 8) return Error.BufferTooSmall;
        buf[0] = @intCast((value >> 56) | 0xC0);
        buf[1] = @intCast((value >> 48) & 0xFF);
        buf[2] = @intCast((value >> 40) & 0xFF);
        buf[3] = @intCast((value >> 32) & 0xFF);
        buf[4] = @intCast((value >> 24) & 0xFF);
        buf[5] = @intCast((value >> 16) & 0xFF);
        buf[6] = @intCast((value >> 8) & 0xFF);
        buf[7] = @intCast(value & 0xFF);
        return 8;
    }
    return Error.TooLarge;
}

/// Returns decoded value; offset advanced past consumed bytes.
pub fn decode(data: []const u8, offset: *usize) Error!u64 {
    if (offset.* >= data.len) return Error.Truncated;
    const first: u64 = data[offset.*];
    const tag: u2 = @truncate(first >> 6);
    const len: usize = switch (tag) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
    };
    // Subtract before comparing so a hostile offset cannot wrap the
    // addition on targets where usize is narrower.
    if (offset.* > data.len or len > data.len - offset.*) return Error.Truncated;
    var value: u64 = first & 0x3F;
    for (1..len) |i| {
        value = (value << 8) | data[offset.* + i];
    }
    offset.* += len;
    return value;
}

test "varint roundtrip all ranges" {
    var buf: [8]u8 = undefined;
    const values = [_]u64{ 0, 63, 64, 16383, 16384, 1073741823, 1073741824, 4611686018427387903 };
    for (values) |v| {
        const n = try encode(&buf, v);
        var offset: usize = 0;
        const d = try decode(buf[0..n], &offset);
        try std.testing.expectEqual(v, d);
        try std.testing.expectEqual(n, offset);
    }
}

test "varint known encodings" {
    var buf: [8]u8 = undefined;
    _ = try encode(&buf, 15293);
    try std.testing.expectEqual(@as(u8, 0x7B), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBD), buf[1]);
}

test "decode rejects an out-of-range offset without wrapping" {
    const data = [_]u8{0xC0};
    var offset: usize = std.math.maxInt(usize);
    try std.testing.expectError(Error.Truncated, decode(&data, &offset));
}
