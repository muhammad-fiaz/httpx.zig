//! Incremental decompression with StreamingDecompressor: the compressed
//! stream is fed in small chunks and output is drained as it appears.

const std = @import("std");
const brotli = @import("brotli");

/// A valid one-metablock stream that decodes to zero bytes.
const sample_stream = [_]u8{0x06};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sd = brotli.StreamingDecompressor.init(allocator, .{});
    defer sd.deinit();

    var out_buf: [4096]u8 = undefined;
    var total: usize = 0;

    // Feed the stream in small slices to exercise chunked consumption.
    var i: usize = 0;
    while (i < sample_stream.len) : (i += 3) {
        const end = @min(i + 3, sample_stream.len);
        try sd.feed(sample_stream[i..end]);
        total += try sd.take(&out_buf);
    }
    try sd.feed(&.{});
    while (!sd.isFinished()) total += try sd.take(&out_buf);

    std.debug.print("streamed {d} output bytes\n", .{total});
}
