//! RFC 7932 word transform table data.

/// RFC 7932 transforms string data: length-prefixed strings.
pub const prefix_suffix: [217]u8 = ("\x01 \x02, \x08 of the \x04 of \x02s \x01.\x05 and \x04 in \x01\"\x04 to \x02\">\x01\n\x02. \x01]\x05 for " ++
    "\x03 a \x06 that \x01'\x06 with \x06 from \x04 by \x01(\x06. The \x04 on \x04 as \x04 is \x04ing " ++
    "\x02\n\t\x01:\x03ed \x02=\"\x04 at \x03ly \x01,\x02='\x05.com/\x07. This \x05 not \x03er \x03al \x04ful " ++
    "\x04ive \x05less \x04est \x04ize \x02\xc2\xa0\x04ous \x05 the \x02e \x00").*;

/// Offsets of the length-prefixed strings within prefix_suffix (derived at compile time).
pub const prefix_suffix_map: [50]u16 = blk: {
    var map: [50]u16 = undefined;
    var off: u16 = 0;
    for (0..50) |i| {
        map[i] = off;
        const len = prefix_suffix[off];
        off += 1 + @as(u16, len);
    }
    break :blk map;
};

/// Pre-sliced views of the 50 RFC 7932 prefix and suffix strings.
pub const prefixes_and_suffixes: [50][]const u8 = blk: {
    var arr: [50][]const u8 = undefined;
    for (0..50) |i| {
        const off = prefix_suffix_map[i];
        const len = prefix_suffix[off];
        arr[i] = prefix_suffix[off + 1 .. off + 1 + len];
    }
    break :blk arr;
};

/// Raw binary transforms data: [prefix_id, type, suffix_id] triplets (363 bytes).
pub const transforms_data: *const [363]u8 = @embedFile("transform_data.bin");

pub const num_transforms = transforms_data.len / 3;

/// Indices of transforms like ["", OMIT_LAST_#, """]; 0-th is identity.
pub const cut_off_transforms = [10]i16{ 0, 12, 27, 23, 42, 63, 56, 48, 59, 64 };

pub const Transform = struct {
    prefix_id: u8,
    type_id: u8,
    suffix_id: u8,
};

/// Structured transform definitions (121 transforms).
pub const transforms: [num_transforms]Transform = blk: {
    var arr: [num_transforms]Transform = undefined;
    for (0..num_transforms) |i| {
        arr[i] = .{
            .prefix_id = transforms_data[i * 3 + 0],
            .type_id = transforms_data[i * 3 + 1],
            .suffix_id = transforms_data[i * 3 + 2],
        };
    }
    break :blk arr;
};

const std = @import("std");

test "transform table counts are self-consistent" {
    try std.testing.expectEqual(@as(usize, 121), num_transforms);
    try std.testing.expectEqual(@as(usize, 50), prefix_suffix_map.len);
    for (prefix_suffix_map) |id| {
        try std.testing.expect(id < prefix_suffix.len);
    }
    var max_prefix: u16 = 0;
    for (transforms_data[0..], 0..) |b, idx| {
        if (idx % 3 != 0) continue;
        if (b > max_prefix) max_prefix = b;
    }
    try std.testing.expect(max_prefix < prefix_suffix.len);
}
