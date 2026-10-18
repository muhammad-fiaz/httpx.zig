//! Error handling: every failure carries a precise ErrorCode.
//!
//!     zig build run-error_handling

const std = @import("std");
const brotli = @import("brotli");

/// Truncated garbage cannot form a valid window header.
const garbage = [_]u8{ 0x91, 0xff, 0xff, 0xff };

pub fn main() void {
    const output = brotli.decompress(std.heap.page_allocator, &garbage) catch |e| {
        std.debug.print("expected failure: {s}\n", .{@errorName(e)});
        return;
    };
    defer std.heap.page_allocator.free(output);
    std.debug.print("unexpected success: {d} bytes\n", .{output.len});
}
