const std = @import("std");
const httpx = @import("httpx");

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readSliceShort(self: *SliceReader, buf: []u8) !usize {
        const remaining = self.data[self.pos..];
        const n = @min(buf.len, remaining.len);
        if (n == 0) return 0;
        @memcpy(buf[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var compressor = httpx.StreamingCompressor.init(allocator, .gzip);
    defer compressor.deinit();
    try compressor.start();

    const chunks = [_][]const u8{
        "This is chunk 1 of the streaming compression example. ",
        "This is chunk 2 with more data to compress. ",
        "This is the final chunk completing the message!",
    };

    for (chunks) |chunk| {
        try compressor.writeChunk(chunk);
    }
    try compressor.finish();

    const compressed = try compressor.toOwnedSlice();
    defer allocator.free(compressed);

    std.debug.print("  Original size: ~{d} bytes (3 chunks)\n", .{"This is chunk 1 of the streaming compression example. This is chunk 2 with more data to compress. This is the final chunk completing the message!".len});
    std.debug.print("  Compressed:    {d} bytes\n", .{compressed.len});

    const reader = SliceReader{ .data = compressed };
    var decompressor = httpx.StreamingDecompressor(SliceReader).init(
        allocator,
        .gzip,
        reader,
    );
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var chunk_count: usize = 0;
    while (try decompressor.readChunk()) |chunk| {
        chunk_count += 1;
        try result.appendSlice(allocator, chunk);
    }

    std.debug.print("  Decompressed in {d} chunks\n", .{chunk_count});
    std.debug.print("  Result: \"{s}\"\n", .{result.items});

    var deflate_compressor = httpx.StreamingCompressor.init(allocator, .deflate);
    defer deflate_compressor.deinit();
    try deflate_compressor.start();
    try deflate_compressor.writeChunk("Deflate streaming test data");
    try deflate_compressor.finish();

    const deflate_compressed = try deflate_compressor.toOwnedSlice();
    defer allocator.free(deflate_compressed);

    const deflate_reader = SliceReader{ .data = deflate_compressed };
    var deflate_decompressor = httpx.StreamingDecompressor(SliceReader).init(
        allocator,
        .deflate,
        deflate_reader,
    );
    defer deflate_decompressor.deinit();

    var deflate_result: std.ArrayList(u8) = .empty;
    defer deflate_result.deinit(allocator);

    while (try deflate_decompressor.readChunk()) |chunk| {
        try deflate_result.appendSlice(allocator, chunk);
    }

    std.debug.print("  Deflate result: \"{s}\"\n", .{deflate_result.items});

    const identity_data = "Raw uncompressed data passed through";
    const id_reader = SliceReader{ .data = identity_data };
    var id_decompressor = httpx.StreamingDecompressor(SliceReader).init(
        allocator,
        .identity,
        id_reader,
    );
    defer id_decompressor.deinit();

    while (try id_decompressor.readChunk()) |chunk| {
        std.debug.print("  Identity chunk: \"{s}\"\n", .{chunk});
    }
}
