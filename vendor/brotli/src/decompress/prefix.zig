//! Decoder-side prefix code lookup tables.
//! kCmdLut is generated at compile time using the format construction
//! algorithm described in RFC 7932.

const std = @import("std");
const constants = @import("../common/constants.zig");
pub const ranges = @import("../common/prefix_ranges.zig");

/// Lookup entry for one insert-and-copy length symbol.
pub const CmdLutElement = extern struct {
    insert_len_extra_bits: u8,
    copy_len_extra_bits: u8,
    /// -1 when a distance must be read, else the implicit distance short code.
    distance_code: i8,
    context: u8,
    insert_len_offset: u16,
    copy_len_offset: u16,
};

pub const kInsertLengthExtraBits = ranges.kInsertLengthExtraBits;
pub const kCopyLengthExtraBits = ranges.kCopyLengthExtraBits;
pub const insert_length_offsets = ranges.insert_length_offsets;
pub const copy_length_offsets = ranges.copy_length_offsets;
const kCellPos = [11]u8{ 0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18 };

fn buildCmdLut() [constants.NUM_COMMAND_SYMBOLS]CmdLutElement {
    @setEvalBranchQuota(100000);
    var items: [constants.NUM_COMMAND_SYMBOLS]CmdLutElement = undefined;

    for (0..constants.NUM_COMMAND_SYMBOLS) |symbol| {
        const cell_idx = symbol >> 6;
        const cell_pos = kCellPos[cell_idx];
        const copy_code = ((@as(usize, cell_pos) << 3) & 0x18) + (symbol & 0x7);
        const copy_len_offset = copy_length_offsets[copy_code];
        const insert_code = (@as(usize, cell_pos) & 0x18) + ((symbol >> 3) & 0x7);
        items[symbol] = .{
            .copy_len_extra_bits = kCopyLengthExtraBits[copy_code],
            .context = if (copy_len_offset > 4) 3 else @intCast(copy_len_offset - 2),
            .copy_len_offset = @intCast(copy_len_offset),
            .distance_code = if (cell_idx >= 2) -1 else 0,
            .insert_len_extra_bits = kInsertLengthExtraBits[insert_code],
            .insert_len_offset = @intCast(insert_length_offsets[insert_code]),
        };
    }
    return items;
}

/// Table mapping each command symbol to its insert/copy lengths, extra bit
/// counts, implicit-distance flag and copy-length context.
pub const cmd_lut = buildCmdLut();

/// Static prefix code for the complex code length code lengths:
/// peeked 4 bits -> (code length consumed, value).
/// Code-length code prefix tables (kCodeLengthPrefixLength / kCodeLengthPrefixValue).
pub const code_length_prefix_order = [constants.CODE_LENGTH_CODES]u8{
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

pub const code_length_prefix_length = [16]u8{
    2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4,
};

pub const code_length_prefix_value = [16]u8{
    0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5,
};

test "cmd lut spot checks" {
    // Symbol 0: insert len 0, copy len 2, implicit distance 0.
    try std.testing.expectEqual(@as(u16, 0), cmd_lut[0].insert_len_offset);
    try std.testing.expectEqual(@as(u16, 2), cmd_lut[0].copy_len_offset);
    try std.testing.expectEqual(@as(i8, 0), cmd_lut[0].distance_code);
    try std.testing.expectEqual(@as(u8, 0), cmd_lut[0].context);
    // Cell 2+ implies explicit distance.
    try std.testing.expectEqual(@as(i8, -1), cmd_lut[128].distance_code);
    // Largest insert offset.
    try std.testing.expectEqual(@as(u16, 22594), cmd_lut[703].insert_len_offset);
}
