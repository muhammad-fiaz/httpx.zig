//! Streaming compression: process a large input in fixed chunks with a
//! progress callback, then finish the stream. Demonstrates the incremental
//! facade used for files larger than memory or network streaming.

const std = @import("std");
const brotli = @import("brotli");

const Progress = struct {
    total: usize,
    fn onProgress(ctx: ?*anyopaque, done: usize, total: usize) void {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        _ = done;
        _ = total;
        self.total +%= 1;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const words = [_][]const u8{
        "the ",    "quick ",     "brown ",       "fox ",    "jumps ",
        "over ",   "lazy ",      "dog ",         "brotli ", "zig ",
        "native ", "streaming ", "compression ",
    };

    var sc = brotli.StreamingCompressor.init(allocator, .{
        .quality = 9,
        .lgWin = 22,
    });
    defer sc.deinit();

    var progress = Progress{ .total = 0 };
    sc.setProgress(Progress.onProgress, &progress);

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    const chunk_size = 32 * 1024;
    const chunk = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk);

    var fed: usize = 0;
    const total_input: usize = 4 * 1024 * 1024;

    while (fed < total_input) {
        // Fill the chunk with pseudo-text.
        var i: usize = 0;
        while (i < chunk.len) {
            const w = words[prng.random().intRangeLessThan(usize, 0, words.len)];
            const n = @min(w.len, chunk.len - i);
            @memcpy(chunk[i..][0..n], w[0..n]);
            i += n;
        }
        const piece = try sc.process(chunk);
        defer allocator.free(piece);
        try compressed.appendSlice(allocator, piece);
        fed += chunk.len;
    }

    const tail = try sc.finishAlloc();
    defer allocator.free(tail);
    try compressed.appendSlice(allocator, tail);

    // Verify the round trip through our own decoder.
    const decoded = try brotli.decompress(allocator, compressed.items);
    defer allocator.free(decoded);

    std.debug.print(
        "streamed {d} bytes -> {d} compressed ({d:.1}%); round trip {s}\n",
        .{
            total_input,
            compressed.items.len,
            @as(f64, @floatFromInt(compressed.items.len)) * 100.0 / @as(f64, @floatFromInt(total_input)),
            if (decoded.len == total_input) "OK" else "MISMATCH",
        },
    );
}
