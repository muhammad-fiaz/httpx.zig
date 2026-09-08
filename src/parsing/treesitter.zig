//! Tree-sitter internal integration bridge for HTTPX HTML and document parsing.
//!
//! Exposes an internal Tree-sitter parser, incremental parse manager, source location
//! ranges, and custom Reader/stream input processing. This file is STRICTLY INTERNAL
//! to HTTPX: users never import it directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const treesitter = @import("treesitter");
const dom = @import("dom.zig");

pub const Point = treesitter.Point;
pub const Range = treesitter.Range;
pub const InputEdit = treesitter.InputEdit;
pub const TsParser = treesitter.Parser;
pub const TsTree = treesitter.Tree;
pub const TsNode = treesitter.Node;
pub const TsLanguage = treesitter.Language;
pub const ReaderSource = treesitter.ReaderSource;

/// Computes an InputEdit for a replacement within source text.
pub fn computeEdit(
    old_source: []const u8,
    start_byte: usize,
    old_len: usize,
    new_len: usize,
    new_source: []const u8,
) InputEdit {
    const start_point = pointForOffset(old_source, start_byte);
    const old_end_point = pointForOffset(old_source, start_byte + old_len);
    const new_end_point = pointForOffset(new_source, start_byte + new_len);

    return .{
        .start_byte = @intCast(start_byte),
        .old_end_byte = @intCast(start_byte + old_len),
        .new_end_byte = @intCast(start_byte + new_len),
        .start_point = start_point,
        .old_end_point = old_end_point,
        .new_end_point = new_end_point,
    };
}

/// Computes a Point (row, column) for a given byte offset in UTF-8 text.
pub fn pointForOffset(source: []const u8, offset: usize) Point {
    const clamped = @min(offset, source.len);
    var row: u32 = 0;
    var col: u32 = 0;
    for (source[0..clamped]) |b| {
        if (b == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .column = col };
}

/// Converts a byte offset range to a Range with start and end Points.
pub fn rangeForBytes(source: []const u8, start: usize, end: usize) Range {
    return .{
        .start_byte = @intCast(start),
        .end_byte = @intCast(end),
        .start_point = pointForOffset(source, start),
        .end_point = pointForOffset(source, end),
    };
}

/// Changes detected between an old tree and a new tree.
pub const ChangedRange = struct {
    start_byte: u32,
    end_byte: u32,
    start_point: Point,
    end_point: Point,
};

/// Compares old and new DOM/Tree-sitter structures and returns byte ranges that changed.
pub fn getChangedByteRanges(
    allocator: Allocator,
    old_tree: *const TsTree,
    new_tree: *const TsTree,
) ![]ChangedRange {
    const ts_ranges = try treesitter.getChangedRanges(allocator, old_tree, new_tree);
    defer treesitter.freeChangedRanges(allocator, ts_ranges);

    const out = try allocator.alloc(ChangedRange, ts_ranges.len);
    for (ts_ranges, 0..) |r, i| {
        out[i] = .{
            .start_byte = r.start_byte,
            .end_byte = r.end_byte,
            .start_point = r.start_point,
            .end_point = r.end_point,
        };
    }
    return out;
}

test "computeEdit correctly tracks points" {
    const old_s = "hello\nworld";
    const new_s = "hello\nbeautiful world";
    const edit = computeEdit(old_s, 6, 0, 10, new_s);
    try std.testing.expectEqual(@as(u32, 6), edit.start_byte);
    try std.testing.expectEqual(@as(u32, 6), edit.old_end_byte);
    try std.testing.expectEqual(@as(u32, 16), edit.new_end_byte);
    try std.testing.expectEqual(@as(u32, 1), edit.start_point.row);
    try std.testing.expectEqual(@as(u32, 0), edit.start_point.column);
}
