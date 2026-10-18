//! Decompress the `sample.br` file produced by the compression example.
//! Demonstrates file-based one-shot decompression with verification.
//!
//!     zig build run-decompress_file
//!
//! If `sample.br` is missing (e.g. this example runs standalone), it is
//! generated first from the embedded sample text so the demo always works.

const std = @import("std");
const brotli = @import("brotli");

const words = [_][]const u8{
    "the ",    "quick ", "brown ",     "fox ",         "jumps ",
    "over ",   "lazy ",  "dog ",       "brotli ",      "zig ",
    "native ", "codec ", "streaming ", "compression ",
};

/// Regenerates the exact corpus used by the compression example.
fn buildSample(allocator: std.mem.Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const total_input: usize = 256 * 1024;
    const input = try allocator.alloc(u8, total_input);
    errdefer allocator.free(input);

    var filled: usize = 0;
    while (filled < input.len) {
        const w = words[prng.random().intRangeLessThan(usize, 0, words.len)];
        const n = @min(w.len, input.len - filled);
        @memcpy(input[filled..][0..n], w[0..n]);
        filled += n;
    }
    return input;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Locate or create the compressed input.
    var compressed: []u8 = undefined;
    if (std.Io.Dir.cwd().readFileAlloc(io, "sample.br", allocator, .limited(4 * 1024 * 1024))) |from_disk| {
        compressed = from_disk;
        std.debug.print("reading existing sample.br ({d} bytes)\n", .{compressed.len});
    } else |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("sample.br not found; generating it first\n", .{});
            const sample = try buildSample(allocator);
            defer allocator.free(sample);
            compressed = try brotli.compressWithOptions(allocator, sample, .{
                .quality = 9,
                .lgWin = 22,
            });
            // Persist it so subsequent runs exercise the on-disk path.
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "sample.br", .data = compressed });
            std.debug.print("created sample.br ({d} bytes)\n", .{compressed.len});
        },
        else => return error.UnreadableInput,
    }
    defer allocator.free(compressed);

    // Decompress the on-disk stream.
    var timer_buf: usize = 0;
    _ = &timer_buf;
    const output = try brotli.decompress(allocator, compressed);
    defer allocator.free(output);

    // Verify against the expected original content.
    const expected = try buildSample(allocator);
    defer allocator.free(expected);

    const match = std.mem.eql(u8, output, expected);

    std.debug.print(
        "decompressed {d} -> {d} bytes; content {s}\n",
        .{ compressed.len, output.len, if (match) "OK" else "MISMATCH" },
    );
    if (!match) return error.RoundTripMismatch;
}
