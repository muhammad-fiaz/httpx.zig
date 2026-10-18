//! Introspecting format constants exposed by the library.

const std = @import("std");
const brotli = @import("brotli");

pub fn main() void {
    std.debug.print("library version : {s} ({d})\n", .{ brotli.versionString(), brotli.versionNumber() });
    std.debug.print("format spec     : {s}\n", .{brotli.spec_version});
    std.debug.print("quality range   : {d}..{d} (default {d})\n", .{
        brotli.MIN_QUALITY, brotli.MAX_QUALITY, brotli.DEFAULT_QUALITY,
    });
    std.debug.print("window bits     : {d}..{d} (large: up to {d})\n", .{
        brotli.MIN_WINDOW_BITS, brotli.MAX_WINDOW_BITS, brotli.LARGE_MAX_WINDOW_BITS,
    });
    std.debug.print("literal symbols : {d}\n", .{brotli.NUM_LITERAL_SYMBOLS});
    std.debug.print("command symbols : {d}\n", .{brotli.NUM_COMMAND_SYMBOLS});
    std.debug.print("distance shorts : {d}\n", .{brotli.NUM_DISTANCE_SHORT_CODES});
}
