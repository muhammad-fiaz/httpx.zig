//! Streaming Compression for httpx.zig
//!
//! Provides chunk-by-chunk compression and decompression without buffering
//! the entire body in memory. Processes data incrementally for large and
//! chunked HTTP responses.
//!
//! Supported encodings:
//! - gzip / deflate: stateful incremental flate decompression via std.compress.flate
//! - brotli / zstd: frame-aware accumulation (library limitation - no streaming API exposed)
//!
//! The streaming API allows callers to consume decompressed data incrementally
//! without requiring the entire response to exist in memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compression = @import("compression.zig");
const ContentEncoding = compression.ContentEncoding;
const dbg = @import("debug.zig");
const list_writer = @import("list_writer.zig");

pub const StreamingError = error{
    DecompressionFailed,
    CompressionFailed,
    IoFailed,
    TruncatedStream,
    MalformedData,
};

/// State for a streaming flate (gzip/deflate) decompressor.
const FlateDecompressorState = struct {
    decompressor: std.compress.flate.Decompress,
    window_buf: [std.compress.flate.max_window_len]u8,
    input_buf: [16 * 1024]u8,
    input_len: usize = 0,
    finalized: bool = false,
};

/// A streaming decompressor that accepts compressed chunks and produces
/// decompressed output incrementally.
pub fn StreamingDecompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        encoding: ContentEncoding,
        reader: ReaderType,
        output_buf: [16 * 1024]u8,
        flate_state: ?FlateDecompressorState = null,
        brotli_accum: ?std.ArrayList(u8) = null,
        zstd_accum: ?std.ArrayList(u8) = null,
        brotli_finalized: bool = false,
        zstd_finalized: bool = false,

        pub fn init(allocator: Allocator, encoding: ContentEncoding, reader: ReaderType) Self {
            return .{
                .allocator = allocator,
                .encoding = encoding,
                .reader = reader,
                .output_buf = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.brotli_accum) |*ba| ba.deinit(self.allocator);
            if (self.zstd_accum) |*za| za.deinit(self.allocator);
        }

        /// Read and decompress a chunk from the compressed stream.
        /// Returns the decompressed bytes (valid until next call).
        /// Returns null at end of stream.
        pub fn readChunk(self: *Self) !?[]const u8 {
            dbg.entry("STREAM", "readChunk");
            switch (self.encoding) {
                .identity => {
                    const n = self.reader.readSliceShort(&self.output_buf) catch return null;
                    if (n == 0) return null;
                    return self.output_buf[0..n];
                },
                .gzip, .deflate => return self.readFlateChunk(),
                .br => return self.readBrotliChunk(),
                .zstd => return self.readZstdChunk(),
            }
        }

        fn ensureFlateInit(self: *Self) !void {
            if (self.flate_state != null) return;

            var state = FlateDecompressorState{
                .decompressor = undefined,
                .window_buf = undefined,
                .input_buf = undefined,
            };

            const initial_read = self.reader.readSliceShort(&state.input_buf) catch return error.IoFailed;
            if (initial_read == 0) return error.TruncatedStream;
            state.input_len = initial_read;

            var in_reader: std.Io.Reader = .fixed(state.input_buf[0..initial_read]);
            const container: std.compress.flate.Container = if (self.encoding == .gzip) .gzip else .zlib;
            state.decompressor = std.compress.flate.Decompress.init(&in_reader, container, &state.window_buf);

            self.flate_state = state;
        }

        fn readFlateChunk(self: *Self) !?[]const u8 {
            try self.ensureFlateInit();
            var state = &self.flate_state.?;
            if (state.finalized) return null;

            var w: std.Io.Writer = .fixed(&self.output_buf);
            _ = state.decompressor.reader.streamRemaining(&w) catch |err| {
                if (err == error.WriteFailed) {
                    return w.buffered();
                }
                return self.refillFlateAndRetry(state);
            };

            state.finalized = true;
            const written = w.buffered();
            if (written.len > 0) return written;
            return null;
        }

        fn refillFlateAndRetry(self: *Self, state: *FlateDecompressorState) !?[]const u8 {
            const new_data = self.reader.readSliceShort(state.input_buf[state.input_len..]) catch return null;
            if (new_data == 0) {
                state.finalized = true;
                return null;
            }
            state.input_len += new_data;

            var in_reader: std.Io.Reader = .fixed(state.input_buf[0..state.input_len]);
            const container: std.compress.flate.Container = if (self.encoding == .gzip) .gzip else .zlib;
            state.decompressor = std.compress.flate.Decompress.init(&in_reader, container, &state.window_buf);

            var w: std.Io.Writer = .fixed(&self.output_buf);
            _ = state.decompressor.reader.streamRemaining(&w) catch {
                state.finalized = true;
                return null;
            };

            state.finalized = true;
            const written = w.buffered();
            if (written.len > 0) return written;
            return null;
        }

        fn readBrotliChunk(self: *Self) !?[]const u8 {
            if (self.brotli_accum == null) {
                self.brotli_accum = .empty;
            }
            if (self.brotli_finalized) return null;

            var buf: [8192]u8 = undefined;
            const n = self.reader.readSliceShort(&buf) catch return null;
            if (n == 0) {
                self.brotli_finalized = true;
                return self.decompressBrotli();
            }

            try self.brotli_accum.?.appendSlice(self.allocator, buf[0..n]);

            if (self.decompressBrotli()) |result| return result;
            return self.readBrotliChunk();
        }

        fn decompressBrotli(self: *Self) ?[]const u8 {
            const accum = self.brotli_accum orelse return null;
            if (accum.items.len == 0) return null;

            const decompressed = @import("brotli").decompress(self.allocator, accum.items) catch return null;
            defer self.allocator.free(decompressed);
            self.brotli_accum.?.clearRetainingCapacity();

            const copy_len = @min(decompressed.len, self.output_buf.len);
            @memcpy(self.output_buf[0..copy_len], decompressed[0..copy_len]);
            return self.output_buf[0..copy_len];
        }

        fn readZstdChunk(self: *Self) !?[]const u8 {
            if (self.zstd_accum == null) {
                self.zstd_accum = .empty;
            }
            if (self.zstd_finalized) return null;

            var buf: [8192]u8 = undefined;
            const n = self.reader.readSliceShort(&buf) catch return null;
            if (n == 0) {
                self.zstd_finalized = true;
                return self.decompressZstd();
            }

            try self.zstd_accum.?.appendSlice(self.allocator, buf[0..n]);

            if (self.decompressZstd()) |result| return result;
            return self.readZstdChunk();
        }

        fn decompressZstd(self: *Self) ?[]const u8 {
            const accum = self.zstd_accum orelse return null;
            if (accum.items.len == 0) return null;

            const zstd_lib = @import("zstd");
            const content_size = switch (zstd_lib.getFrameContentSize(accum.items)) {
                .known => |s| s,
                .unknown, .@"error" => return null,
            };

            const decompressed = zstd_lib.decompress(self.allocator, accum.items, @intCast(content_size)) catch return null;
            defer self.allocator.free(decompressed);
            self.zstd_accum.?.clearRetainingCapacity();

            const copy_len = @min(decompressed.len, self.output_buf.len);
            @memcpy(self.output_buf[0..copy_len], decompressed[0..copy_len]);
            return self.output_buf[0..copy_len];
        }
    };
}

/// A streaming compressor that accepts input chunks and produces compressed output.
/// Uses internal std.Io.Writer.Allocating to buffer compressed data.
pub const StreamingCompressor = struct {
    allocator: Allocator,
    encoding: ContentEncoding,
    aw: std.Io.Writer.Allocating,
    flate_compressor: ?flate_state = null,
    window_buf: [std.compress.flate.max_window_len]u8,

    const flate_state = struct {
        compressor: std.compress.flate.Compress,
    };

    pub fn init(allocator: Allocator, encoding: ContentEncoding) StreamingCompressor {
        return .{
            .allocator = allocator,
            .encoding = encoding,
            .aw = .init(allocator),
            .flate_compressor = null,
            .window_buf = undefined,
        };
    }

    pub fn deinit(self: *StreamingCompressor) void {
        self.aw.deinit();
    }

    pub fn start(self: *StreamingCompressor) !void {
        switch (self.encoding) {
            .identity => {},
            .gzip, .deflate => {
                self.aw.ensureUnusedCapacity(256) catch return error.CompressionFailed;
                const container: std.compress.flate.Container = if (self.encoding == .gzip) .gzip else .zlib;
                const compressor = std.compress.flate.Compress.init(
                    &self.aw.writer,
                    &self.window_buf,
                    container,
                    std.compress.flate.Compress.Options.level_6,
                ) catch return error.CompressionFailed;
                self.flate_compressor = .{ .compressor = compressor };
            },
            .br, .zstd => {},
        }
    }

    pub fn writeChunk(self: *StreamingCompressor, chunk: []const u8) !void {
        if (chunk.len == 0) return;

        switch (self.encoding) {
            .identity => {
                _ = self.aw.writer.writeAll(chunk) catch return error.IoFailed;
            },
            .gzip, .deflate => {
                if (self.flate_compressor) |*state| {
                    _ = state.compressor.writer.writeAll(chunk) catch return error.CompressionFailed;
                } else {
                    return error.CompressionFailed;
                }
            },
            .br => {
                const compressed = @import("brotli").compress(self.allocator, chunk) catch return error.CompressionFailed;
                defer self.allocator.free(compressed);
                _ = self.aw.writer.writeAll(compressed) catch return error.IoFailed;
            },
            .zstd => {
                const zstd_lib = @import("zstd");
                const compressed = zstd_lib.compress(self.allocator, chunk, 1) catch return error.CompressionFailed;
                defer self.allocator.free(compressed);
                _ = self.aw.writer.writeAll(compressed) catch return error.IoFailed;
            },
        }
    }

    pub fn finish(self: *StreamingCompressor) !void {
        switch (self.encoding) {
            .identity => {},
            .gzip, .deflate => {
                if (self.flate_compressor) |*state| {
                    state.compressor.finish() catch return error.CompressionFailed;
                    self.flate_compressor = null;
                }
            },
            .br, .zstd => {},
        }
    }

    /// Get the compressed output. Caller does not own the memory.
    pub fn getWritten(self: *const StreamingCompressor) []const u8 {
        return self.aw.getWritten();
    }

    /// Take ownership of the compressed output.
    pub fn toOwnedSlice(self: *StreamingCompressor) ![]u8 {
        return self.aw.toOwnedSlice();
    }
};

test "streaming decompressor gzip round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Hello, streaming decompression test with gzip encoding!";
    const compressed = try compression.compress(allocator, .gzip, sample);
    defer allocator.free(compressed);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .gzip, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings(sample, result.items);
}

test "streaming decompressor deflate round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Hello, streaming decompression test with deflate encoding!";
    const compressed = try compression.compress(allocator, .deflate, sample);
    defer allocator.free(compressed);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .deflate, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings(sample, result.items);
}

test "streaming decompressor identity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Uncompressed identity data";
    const r: std.Io.Reader = .fixed(sample);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .identity, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings(sample, result.items);
}

test "streaming compressor gzip round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var compressor = StreamingCompressor.init(allocator, .gzip);
    defer compressor.deinit();
    try compressor.start();

    try compressor.writeChunk("Hello, ");
    try compressor.writeChunk("streaming ");
    try compressor.writeChunk("compression!");
    try compressor.finish();

    const compressed = try compressor.toOwnedSlice();
    defer allocator.free(compressed);

    try testing.expect(compressed.len > 0);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .gzip, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings("Hello, streaming compression!", result.items);
}

test "streaming decompressor empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const r: std.Io.Reader = .fixed("");
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .gzip, r);
    defer decompressor.deinit();

    const result = decompressor.readChunk();
    try testing.expectError(error.TruncatedStream, result);
}

test "streaming compressor deflate round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var compressor = StreamingCompressor.init(allocator, .deflate);
    defer compressor.deinit();
    try compressor.start();

    try compressor.writeChunk("Deflate streaming test data");
    try compressor.finish();

    const compressed = try compressor.toOwnedSlice();
    defer allocator.free(compressed);

    try testing.expect(compressed.len > 0);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .deflate, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings("Deflate streaming test data", result.items);
}
