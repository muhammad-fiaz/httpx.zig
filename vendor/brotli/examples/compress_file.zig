//! One-shot compression: writes a sample input file and its Brotli-compressed
//! counterpart to disk. The generated `sample.br` is intentionally kept so
//! the `decompress_file` example (or any other tool) can consume it.
//!
//!     zig build run-compress_file

const std = @import("std");
const brotli = @import("brotli");

const words = [_][]const u8{
    "the ",    "quick ", "brown ",     "fox ",         "jumps ",
    "over ",   "lazy ",  "dog ",       "brotli ",      "zig ",
    "native ", "codec ", "streaming ", "compression ",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Build a deterministic pseudo-text corpus (~256 KiB).
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const total_input: usize = 256 * 1024;
    const input = try allocator.alloc(u8, total_input);
    defer allocator.free(input);

    var filled: usize = 0;
    while (filled < input.len) {
        const w = words[prng.random().intRangeLessThan(usize, 0, words.len)];
        const n = @min(w.len, input.len - filled);
        @memcpy(input[filled..][0..n], w[0..n]);
        filled += n;
    }

    // Persist the raw input alongside the compressed output so the
    // decompression example can verify the round trip byte-for-byte.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "sample.txt", .data = input });

    // Compress at several quality levels; keep only the q9 result on disk.
    inline for (.{ 1, 5, 9, 11 }) |q| {
        const compressed = try brotli.compressWithOptions(allocator, input, .{
            .quality = q,
            .lgWin = 22,
        });
        defer allocator.free(compressed);

        if (q == 9) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "sample.br", .data = compressed });
        }

        std.debug.print(
            "q{d:<2}: {d} -> {d} bytes ({d:.1}% ratio){s}\n",
            .{
                q,
                input.len,
                compressed.len,
                @as(f64, @floatFromInt(compressed.len)) * 100.0 / @as(f64, @floatFromInt(input.len)),
                if (q == 9) "  [written to sample.br]" else "",
            },
        );
    }

    // Read-back sanity check straight from disk.
    const from_disk = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "sample.br",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(from_disk);

    const round_trip = try brotli.decompress(allocator, from_disk);
    defer allocator.free(round_trip);

    std.debug.print(
        "wrote sample.txt ({d} B) and sample.br ({d} B); disk round-trip {s}\n",
        .{
            input.len,
            from_disk.len,
            if (std.mem.eql(u8, round_trip, input)) "OK" else "MISMATCH",
        },
    );
}
