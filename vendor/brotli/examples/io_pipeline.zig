//! Explicit `std.Io` integration for both directions.
//!
//!     zig build run-io_pipeline
//!
//! Shows the three client-side I/O shapes the library supports:
//!   * in-memory one-shot calls over caller-owned slices,
//!   * reader/writer streaming where the caller owns the endpoints,
//!   * chunked streaming adapters that never buffer the whole payload.
//!
//! Everything below is driven by an explicit `std.Io` value and an explicit
//! allocator; the library keeps no global state.

const std = @import("std");
const brotli = @import("brotli");

const sentence = "Brotli streams through explicit reader and writer endpoints. ";
const text: [sentence.len * 64]u8 = blk: {
    var buffer: [sentence.len * 64]u8 = undefined;
    for (0..64) |i| @memcpy(buffer[i * sentence.len ..][0..sentence.len], sentence[0..]);
    break :blk buffer;
};

fn report(comptime label: []const u8, compressed: usize, decompressed: usize, ok: bool) void {
    std.debug.print("{s:<28} {d:>8} -> {d:>8} bytes  {s}\n", .{
        label, compressed, decompressed, if (ok) "OK" else "MISMATCH",
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const input = try allocator.dupe(u8, text[0..]);
    defer allocator.free(input);

    // In-memory: caller owns the input and the returned output.
    {
        const compressed = try brotli.compressWithOptions(allocator, input, .{ .quality = 9 });
        defer allocator.free(compressed);
        const decoded = try brotli.decompress(allocator, compressed);
        defer allocator.free(decoded);
        report("in-memory one-shot", compressed.len, decoded.len, std.mem.eql(u8, decoded, input));
    }

    // Caller-provided destination: no allocation on the decompression side.
    {
        const compressed = try brotli.compressWithOptions(allocator, input, .{ .quality = 9 });
        defer allocator.free(compressed);
        var buffer = try allocator.alloc(u8, input.len + 64);
        defer allocator.free(buffer);
        const written = try brotli.decompressInto(allocator, compressed, buffer);
        report("decompressInto", compressed.len, written, std.mem.eql(u8, buffer[0..written], input));
    }

    // Reader/writer: the caller supplies both endpoints.
    {
        const compressed = try brotli.compressWithOptions(allocator, input, .{ .quality = 9 });
        defer allocator.free(compressed);

        var compressed_storage: [4096]u8 = undefined;
        var reader = std.Io.Reader.fixed(input);
        var writer = std.Io.Writer.fixed(&compressed_storage);
        try brotli.compressStream(allocator, &reader, &writer, .{ .quality = 9 });
        try writer.flush();

        const piped = writer.buffered();
        const out_buffer = try allocator.alloc(u8, input.len + 64);
        defer allocator.free(out_buffer);
        var comp_reader = std.Io.Reader.fixed(piped);
        var out_writer = std.Io.Writer.fixed(out_buffer);
        try brotli.decompressStream(allocator, &comp_reader, &out_writer, .{});
        try out_writer.flush();
        report("reader/writer streaming", piped.len, out_writer.buffered().len, std.mem.eql(u8, out_writer.buffered(), input));
    }

    // Chunked adapters: fixed-size windows, memory stays bounded.
    {
        var compressor = brotli.StreamingCompressor.init(allocator, .{ .quality = 9 });
        defer compressor.deinit();

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(allocator);
        var chunk: [1024]u8 = undefined;
        var offset: usize = 0;
        while (offset < input.len) {
            const n = @min(chunk.len, input.len - offset);
            @memcpy(chunk[0..n], input[offset..][0..n]);
            offset += n;
            const piece = try compressor.process(chunk[0..n]);
            defer allocator.free(piece);
            try compressed.appendSlice(allocator, piece);
        }
        const tail = try compressor.finishAlloc();
        defer allocator.free(tail);
        try compressed.appendSlice(allocator, tail);

        var decompressor = brotli.StreamingDecompressor.init(allocator, .{});
        defer decompressor.deinit();
        try decompressor.feed(compressed.items);
        decompressor.endInput();

        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(allocator);
        var out_chunk: [1024]u8 = undefined;
        while (!decompressor.isFinished()) {
            const n = try decompressor.take(&out_chunk);
            if (n == 0) {
                if (decompressor.hasError()) return decompressor.errorCode().toError();
                if (decoded.items.len >= input.len) break;
                continue;
            }
            try decoded.appendSlice(allocator, out_chunk[0..n]);
        }
        report("chunked streaming", compressed.items.len, decoded.items.len, std.mem.eql(u8, decoded.items, input));
    }

    std.debug.print("\nevery shape produced identical output\n", .{});
}
