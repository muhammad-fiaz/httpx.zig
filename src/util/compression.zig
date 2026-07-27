//! Compression Utilities for httpx.zig
//!
//! Provides decompression support for Content-Encoding response headers:
//! - gzip (via std.compress.gzip)
//! - deflate (via std.compress.flate)
//! - zstd (optional / fallback stub when zstd is not enabled)

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root");

pub const ContentEncoding = enum {
    gzip,
    deflate,
    zstd,
    identity,

    pub fn fromString(str: []const u8) ?ContentEncoding {
        if (std.ascii.eqlIgnoreCase(str, "gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(str, "deflate")) return .deflate;
        if (std.ascii.eqlIgnoreCase(str, "zstd")) return .zstd;
        if (std.ascii.eqlIgnoreCase(str, "identity")) return .identity;
        return null;
    }
};

/// Decompresses body content based on the provided Content-Encoding.
/// The caller owns the returned slice.
pub fn decompress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8 {
    switch (encoding) {
        .identity => return allocator.dupe(u8, data),
        .gzip => return decompressGzip(allocator, data),
        .deflate => return decompressDeflate(allocator, data),
        .zstd => return decompressZstd(allocator, data),
    }
}

fn decompressGzip(allocator: Allocator, data: []const u8) ![]u8 {
    return decompressFlate(allocator, data, .gzip);
}

fn decompressDeflate(allocator: Allocator, data: []const u8) ![]u8 {
    return decompressFlate(allocator, data, .zlib) catch {
        return decompressFlate(allocator, data, .raw);
    };
}

fn decompressFlate(allocator: Allocator, data: []const u8, container: std.compress.flate.Container) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&in, container, &window_buf);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    _ = decompressor.reader.streamRemaining(&aw.writer) catch return error.DecompressionFailed;
    return aw.toOwnedSlice() catch return error.DecompressionFailed;
}

fn decompressZstd(allocator: Allocator, data: []const u8) ![]u8 {
    if (@hasDecl(root, "zstd")) {
        const zstd = root.zstd;
        const content_size = zstd.c.ZSTD_getFrameContentSize(data.ptr, data.len);
        const ZSTD_CONTENTSIZE_ERROR: u64 = std.math.maxInt(u64) - 1;
        const ZSTD_CONTENTSIZE_UNKNOWN: u64 = std.math.maxInt(u64);

        if (content_size == ZSTD_CONTENTSIZE_ERROR or content_size == ZSTD_CONTENTSIZE_UNKNOWN) {
            return error.DecompressionFailed;
        }

        const dest_buffer = try allocator.alloc(u8, content_size);
        errdefer allocator.free(dest_buffer);

        const dSize = zstd.c.ZSTD_decompress(dest_buffer.ptr, content_size, data.ptr, data.len);
        if (zstd.c.ZSTD_isError(dSize) != 0) {
            return error.DecompressionFailed;
        }

        return dest_buffer[0..dSize];
    }
    return error.ZstdNotSupported;
}

pub fn compressZstd(allocator: Allocator, data: []const u8) ![]u8 {
    if (@hasDecl(root, "zstd")) {
        const zstd = root.zstd;
        const dest_size = zstd.c.ZSTD_compressBound(data.len);
        const dest_buffer = try allocator.alloc(u8, dest_size);
        errdefer allocator.free(dest_buffer);

        const cSize = zstd.c.ZSTD_compress(dest_buffer.ptr, dest_size, data.ptr, data.len, 1);
        if (zstd.c.ZSTD_isError(cSize) != 0) {
            return error.CompressionFailed;
        }

        return allocator.realloc(dest_buffer, cSize) catch dest_buffer[0..cSize];
    }
    return error.ZstdNotSupported;
}

test "compression gzip decompression" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig gzip compression test!";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(1024);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .gzip, std.compress.flate.Compress.Options.level_6) catch unreachable;
    _ = compressor.writer.writeAll(sample_plain) catch unreachable;
    compressor.finish() catch unreachable;

    const compressed_data = try aw.toOwnedSlice();
    defer allocator.free(compressed_data);

    const decompressed = try decompress(allocator, .gzip, compressed_data);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}

test "compression deflate zlib decompression" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig deflate compression test!";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(1024);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .zlib, std.compress.flate.Compress.Options.level_6) catch unreachable;
    _ = compressor.writer.writeAll(sample_plain) catch unreachable;
    compressor.finish() catch unreachable;

    const compressed_data = try aw.toOwnedSlice();
    defer allocator.free(compressed_data);

    const decompressed = try decompress(allocator, .deflate, compressed_data);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}

test "compression identity pass-through" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Uncompressed payload";

    const decompressed = try decompress(allocator, .identity, sample_plain);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}
