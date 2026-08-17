//! Compression Utilities for httpx.zig
//!
//! Provides compression and decompression support for Content-Encoding:
//! - gzip (via std.compress.flate)
//! - deflate (via std.compress.flate)
//! - br / brotli (via brotli package)
//! - zstd (via zstd package)
//! - identity (pass-through)

const std = @import("std");
const Allocator = std.mem.Allocator;
const zstd = @import("zstd");
const brotli = @import("brotli");
const dbg = @import("debug.zig");

pub const ContentEncoding = enum {
    gzip,
    deflate,
    br,
    zstd,
    identity,

    /// All supported Content-Encoding values.
    pub const ALL = [_]ContentEncoding{ .gzip, .deflate, .br, .zstd, .identity };

    /// Builds the Accept-Encoding header value.
    /// Returns all supported encodings regardless of the input array,
    /// as the server may use any encoding and the client should advertise all support.
    pub fn buildAcceptEncoding(encodings: []const ContentEncoding) []const u8 {
        _ = encodings;
        return "gzip, deflate, br, zstd, identity";
    }

    pub fn toString(self: ContentEncoding) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
            .zstd => "zstd",
            .identity => "identity",
        };
    }

    pub fn fromString(str: []const u8) ?ContentEncoding {
        if (std.ascii.eqlIgnoreCase(str, "gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(str, "deflate")) return .deflate;
        if (std.ascii.eqlIgnoreCase(str, "br")) return .br;
        if (std.ascii.eqlIgnoreCase(str, "zstd")) return .zstd;
        if (std.ascii.eqlIgnoreCase(str, "identity")) return .identity;
        return null;
    }
};

/// Decompresses body content based on the provided Content-Encoding.
/// The caller owns the returned slice.
pub fn decompress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8 {
    dbg.entry("COMP", "decompress");
    switch (encoding) {
        .identity => return allocator.dupe(u8, data),
        .gzip => return decompressGzip(allocator, data),
        .deflate => return decompressDeflate(allocator, data),
        .br => return brotli.decompress(allocator, data) catch return error.DecompressionFailed,
        .zstd => return decompressZstd(allocator, data),
    }
}

/// Compresses data using the specified encoding.
/// The caller owns the returned slice.
pub fn compress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8 {
    dbg.entry("COMP", "compress");
    switch (encoding) {
        .identity => return allocator.dupe(u8, data),
        .gzip => return compressGzip(allocator, data),
        .deflate => return compressDeflate(allocator, data),
        .br => return brotli.compress(allocator, data) catch return error.CompressionFailed,
        .zstd => return compressZstd(allocator, data),
    }
}

fn compressGzip(allocator: Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(data.len + 64);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .gzip, std.compress.flate.Compress.Options.level_6) catch return error.CompressionFailed;
    _ = compressor.writer.writeAll(data) catch return error.CompressionFailed;
    compressor.finish() catch return error.CompressionFailed;

    return aw.toOwnedSlice() catch return error.CompressionFailed;
}

fn compressDeflate(allocator: Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(data.len + 64);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .zlib, std.compress.flate.Compress.Options.level_6) catch return error.CompressionFailed;
    _ = compressor.writer.writeAll(data) catch return error.CompressionFailed;
    compressor.finish() catch return error.CompressionFailed;

    return aw.toOwnedSlice() catch return error.CompressionFailed;
}

fn compressZstd(allocator: Allocator, data: []const u8) ![]u8 {
    return zstd.compress(allocator, data, 1) catch return error.CompressionFailed;
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

test "compression gzip round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig gzip compression test!";

    const compressed = try compress(allocator, .gzip, sample_plain);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .gzip, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}

test "compression deflate round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig deflate compression test!";

    const compressed = try compress(allocator, .deflate, sample_plain);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .deflate, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}

test "compression brotli round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig brotli compression test!";

    const compressed = try compress(allocator, .br, sample_plain);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .br, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(sample_plain, decompressed);
}

test "compression zstd round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const sample_plain = "Hello, httpx.zig zstd compression test!";

    const compressed = try compress(allocator, .zstd, sample_plain);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .zstd, compressed);
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
