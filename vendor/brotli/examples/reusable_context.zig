//! Reusing one Decoder across several independent streams.

const std = @import("std");
const brotli = @import("brotli");

const empty_stream = [_]u8{0x06};

fn runOne(decoder: *brotli.Decoder, data: []const u8) !usize {
    decoder.resetForNewStream();
    var input: []const u8 = data;
    var out: [64]u8 = undefined;
    var avail: []u8 = &out;
    var total: u64 = 0;
    switch (decoder.decompressStream(&input, &avail, &total)) {
        .success => {},
        else => return error.StreamFailed,
    }
    return @intCast(total);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const decoder = try allocator.create(brotli.Decoder);
    defer allocator.destroy(decoder);
    decoder.* = brotli.Decoder.init(allocator, .{});
    defer decoder.deinit();

    const first = try runOne(decoder, &empty_stream);
    const second = try runOne(decoder, &empty_stream);
    std.debug.print("two streams on one context: {d}, {d} bytes\n", .{ first, second });
}
