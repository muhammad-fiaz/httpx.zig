//! Custom-dictionary compression round trip: the same dictionary bytes are
//! attached to the encoder and the decoder. The encoder then emits compact
//! back-references into dictionary content, and only the decoder with the
//! identical data attached can expand them.

const std = @import("std");
const brotli = @import("brotli");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Shared secret vocabulary: in real use this could be a trained corpus
    // or domain-specific word list known to both sides.
    const custom_dictionary = "opencode native zig brotli sample vocabulary " ++
        "compression decompression streaming performance ";

    // Input heavily overlapping the dictionary; a plain compressor sees
    // little structure here, but with the dictionary attached most of it
    // collapses into back-references.
    const input = "native zig brotli sample vocabulary compression performance";

    var enc = brotli.Encoder.init(allocator, .{ .quality = 11 });
    defer enc.deinit();
    if (!enc.attachDictionary(custom_dictionary)) return error.InvalidDictionary;

    enc.compressStream(.process, input) catch return error.CompressionFailed;
    enc.compressStream(.finish, null) catch return error.CompressionFailed;
    const compressed = try allocator.dupe(u8, enc.out.items[enc.out_pos..]);
    defer allocator.free(compressed);

    // Decode without the dictionary must fail (or produce garbage): the
    // references point outside the stream.
    var plain = brotli.Decoder.init(allocator, .{});
    defer plain.deinit();
    var pin: []const u8 = compressed;
    var pout: [256]u8 = undefined;
    var pavail: []u8 = &pout;
    var ptotal: u64 = 0;
    const plain_result = plain.decompressStream(&pin, &pavail, &ptotal);

    // Decode WITH the dictionary must reproduce the input exactly.
    var decoder = brotli.Decoder.init(allocator, .{});
    defer decoder.deinit();
    if (!decoder.attachDictionary(custom_dictionary)) return error.InvalidDictionary;
    var din: []const u8 = compressed;
    var dout: [256]u8 = undefined;
    var davail: []u8 = &dout;
    var dtotal: u64 = 0;
    switch (decoder.decompressStream(&din, &davail, &dtotal)) {
        .success => {},
        else => return error.StreamFailed,
    }

    const recovered = dout[0..@intCast(dtotal)];
    const match = std.mem.eql(u8, recovered, input);
    std.debug.print(
        "{d} -> {d} bytes with shared dictionary; recovered {s} (plain decode: {any})\n",
        .{
            input.len,
            compressed.len,
            if (match) "OK" else "MISMATCH",
            plain_result == .success,
        },
    );
    if (!match) return error.RoundTripMismatch;
}
