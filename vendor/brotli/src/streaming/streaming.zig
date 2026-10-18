//! Streaming Brotli compression and decompression module.

pub const compressor = @import("compressor.zig");
pub const decompressor = @import("decompressor.zig");

pub const StreamingCompressor = compressor.StreamingCompressor;
pub const compressStream = compressor.compressStream;

pub const StreamingDecompressor = decompressor.StreamingDecompressor;
pub const decompressStream = decompressor.decompressStream;

test {
    @import("std").testing.refAllDecls(@This());
}
