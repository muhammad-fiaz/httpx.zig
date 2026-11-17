const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = @import("allocator.zig").allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var document = try httpx.parsing.init(allocator, io, .{}).parseHtml("<main>size</main>");
    defer document.deinit();
    const title = try document.title();
    std.debug.print("{s}\n", .{title});
}
