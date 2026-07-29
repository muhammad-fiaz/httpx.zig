//! Compression Utilities for httpx.zig
//!
//! Provides decompression support for Content-Encoding response headers:
//! - gzip (via std.compress.gzip)
//! - deflate (via std.compress.flate)
//! - zstd (optional / fallback stub when zstd is not enabled)

const std = @import("std");
const Allocator = std.mem.Allocator;
const zstd = @import("zstd");

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
    const content_size = switch (zstd.getFrameContentSize(data)) {
        .known => |size| size,
        .unknown, .@"error" => return error.DecompressionFailed,
    };

    return zstd.decompress(allocator, data, @intCast(content_size)) catch {
        return error.DecompressionFailed;
    };
}

pub fn compressZstd(allocator: Allocator, data: []const u8) ![]u8 {
    return zstd.compress(allocator, data, 1) catch {
        return error.CompressionFailed;
    };
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
