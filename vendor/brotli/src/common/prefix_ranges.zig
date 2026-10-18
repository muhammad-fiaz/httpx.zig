//! Block-length prefix code range table data.

pub const PrefixCodeRange = struct { offset: u16, nbits: u8 };

pub const prefix_code_ranges: [26]PrefixCodeRange = blk: {
    const nbits_table = [26]u8{
        2, 2, 2, 2, 3, 3,  3,  3,  4,  4,  4, 4, 5, 5, 5, 5,
        6, 6, 7, 8, 9, 10, 11, 12, 13, 24,
    };
    var ranges: [26]PrefixCodeRange = undefined;
    var offset: u32 = 1;
    for (0..26) |i| {
        ranges[i] = .{ .offset = @intCast(offset), .nbits = nbits_table[i] };
        offset += @as(u32, 1) << @intCast(nbits_table[i]);
    }
    break :blk ranges;
};

/// Fast search for the block length prefix code (0..25) matching `len`.
pub inline fn findPrefixCode(len: u32) u8 {
    var code: u32 = if (len >= 177) (if (len >= 753) 20 else 14) else (if (len >= 41) 7 else 0);
    while (code < 25 and len >= prefix_code_ranges[code + 1].offset) : (code += 1) {}
    return @intCast(code);
}

/// RFC 7932 extra bits for insert length codes 0..23.
pub const kInsertLengthExtraBits = [24]u8{
    0, 0, 0,  0,  0,  0,  1, 1, 2,
    2, 3, 3,  4,  4,  5,  5, 6, 7,
    8, 9, 10, 12, 14, 24,
};

/// RFC 7932 extra bits for copy length codes 0..23.
pub const kCopyLengthExtraBits = [24]u8{
    0,  0,  0, 0, 0, 0, 0, 0, 1, 1, 2,
    2,  3,  3, 4, 4, 5, 5, 6, 7, 8, 9,
    10, 24,
};

/// Offset of each insert length code 0..23.
pub const insert_length_offsets: [24]u32 = blk: {
    var off: [24]u32 = undefined;
    off[0] = 0;
    for (0..23) |i| off[i + 1] = off[i] + (@as(u32, 1) << @intCast(kInsertLengthExtraBits[i]));
    break :blk off;
};

/// Offset of each copy length code 0..23.
pub const copy_length_offsets: [24]u32 = blk: {
    var off: [24]u32 = undefined;
    off[0] = 2;
    for (0..23) |i| off[i + 1] = off[i] + (@as(u32, 1) << @intCast(kCopyLengthExtraBits[i]));
    break :blk off;
};

/// Fast search for the prefix code (0..23) and extra bits for a given length.
pub inline fn codeFor(off: *const [24]u32, value: u32) struct { code: u8, extra: u32 } {
    if (value < off[8]) {
        var i: usize = 0;
        while (i < 7 and value >= off[i + 1]) : (i += 1) {}
        return .{ .code = @intCast(i), .extra = value - off[i] };
    }
    var left: usize = 8;
    var right: usize = 23;
    while (left < right) {
        const mid = (left + right + 1) / 2;
        if (value >= off[mid]) {
            left = mid;
        } else {
            right = mid - 1;
        }
    }
    return .{ .code = @intCast(left), .extra = value - off[left] };
}

const std = @import("std");

test "block length ranges match the format tables" {
    try std.testing.expectEqual(@as(usize, 26), prefix_code_ranges.len);
    try std.testing.expectEqual(@as(u16, 1), prefix_code_ranges[0].offset);
    try std.testing.expectEqual(@as(u8, 2), prefix_code_ranges[0].nbits);
    try std.testing.expectEqual(@as(u16, 16625), prefix_code_ranges[25].offset);
    try std.testing.expectEqual(@as(u8, 24), prefix_code_ranges[25].nbits);
    var i: usize = 1;
    while (i < prefix_code_ranges.len) : (i += 1) {
        const prev_end = @as(u32, prefix_code_ranges[i - 1].offset) +
            (@as(u32, 1) << @as(u5, @intCast(prefix_code_ranges[i - 1].nbits)));
        try std.testing.expectEqual(prefix_code_ranges[i].offset, @as(u16, @intCast(prev_end)));
    }
}

test "insert and copy length offsets and codeFor consistency" {
    try std.testing.expectEqual(@as(u32, 0), insert_length_offsets[0]);
    try std.testing.expectEqual(@as(u32, 2), copy_length_offsets[0]);

    for (insert_length_offsets, 0..) |off, idx| {
        const res = codeFor(&insert_length_offsets, off);
        try std.testing.expectEqual(@as(u8, @intCast(idx)), res.code);
        try std.testing.expectEqual(@as(u32, 0), res.extra);
    }

    for (copy_length_offsets, 0..) |off, idx| {
        const res = codeFor(&copy_length_offsets, off);
        try std.testing.expectEqual(@as(u8, @intCast(idx)), res.code);
        try std.testing.expectEqual(@as(u32, 0), res.extra);
    }
}
