//! Literal context lookup table data for all context modes.

/// Common context lookup table for all context modes: LSB6/MSB6/UTF8/SIGNED x last/second-last byte.
pub const table: [2048]u8 = @embedFile("context_table.bin").*;

const std = @import("std");

test "context table shape and identifier range" {
    try std.testing.expectEqual(@as(usize, 2048), table.len);
    for (table) |v| {
        // Context identifiers occupy six bits per RFC 7932 section 7.1.
        try std.testing.expect(v < 64);
    }
    try std.testing.expectEqual(@as(u8, 0), table[0]);
}
