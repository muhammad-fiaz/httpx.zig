const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = @import("allocator.zig").allocator;
    const encoded = try httpx.compression.compress(allocator, .gzip, "size-baseline payload");
    defer allocator.free(encoded);
    std.debug.print("{d}\n", .{encoded.len});
}
