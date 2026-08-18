//! Streaming Compression for httpx.zig
//!
//! Provides chunk-by-chunk compression and decompression without buffering
//! the entire body in memory. Processes data incrementally for large and
//! chunked HTTP responses.
//!
//! Supported encodings:
//!   gzip / deflate  -- stateful incremental flate via std.compress.flate
//!   brotli          -- accumulates per-frame, decompresses complete frames
//!   zstd            -- accumulates per-frame, decompresses complete frames
//!   identity        -- passthrough
//!
//! The streaming API allows callers to consume decompressed data incrementally
//! without requiring the entire response to exist in memory.
//!
//! Decompression bomb protection: both StreamingDecompressor and
//! StreamingCompressor enforce configurable size limits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compression = @import("compression.zig");
const ContentEncoding = compression.ContentEncoding;
const brotli = @import("brotli");
const zstd_pkg = @import("zstd");

pub const StreamingError = error{
    DecompressionFailed,
    DecompressionBombDetected,
    CompressionFailed,
    CompressionLimitExceeded,
    IoFailed,
    TruncatedStream,
    MalformedData,
};

pub const StreamingLimits = struct {
    max_decompressed_size: usize = 100 * 1024 * 1024,
    max_compressed_input: usize = 256 * 1024 * 1024,
};

const FlateDecompressorState = struct {
    decompressor: std.compress.flate.Decompress,
    window_buf: [std.compress.flate.max_window_len]u8,
    input_buf: [16 * 1024]u8,
    input_len: usize = 0,
    finalized: bool = false,
};

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
        total_decompressed: usize = 0,
        total_compressed: usize = 0,
        limits: StreamingLimits,

        pub fn init(allocator: Allocator, encoding: ContentEncoding, reader: ReaderType) Self {
            return .{
                .allocator = allocator,
                .encoding = encoding,
                .reader = reader,
                .output_buf = undefined,
                .limits = .{},
            };
        }

        pub fn initWithLimits(allocator: Allocator, encoding: ContentEncoding, reader: ReaderType, limits: StreamingLimits) Self {
            return .{
                .allocator = allocator,
                .encoding = encoding,
                .reader = reader,
                .output_buf = undefined,
                .limits = limits,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.brotli_accum) |*ba| ba.deinit(self.allocator);
            if (self.zstd_accum) |*za| za.deinit(self.allocator);
        }

        pub fn readChunk(self: *Self) !?[]const u8 {
            switch (self.encoding) {
                .identity => {
                    const n = self.reader.readSliceShort(&self.output_buf) catch return null;
                    if (n == 0) return null;
                    self.total_decompressed +|= n;
                    if (self.total_decompressed > self.limits.max_decompressed_size) return error.DecompressionBombDetected;
                    return self.output_buf[0..n];
                },
                .gzip, .deflate => return self.readFlateChunk(),
                .br => return self.readBrotliChunk(),
                .zstd => return self.readZstdChunk(),
            }
        }

        // --- Flate (gzip/deflate) streaming ---

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
            self.total_compressed +|= initial_read;

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
                    const written = w.buffered();
                    self.total_decompressed +|= written.len;
                    if (self.total_decompressed > self.limits.max_decompressed_size) return error.DecompressionBombDetected;
                    return written;
                }
                return self.refillFlateAndRetry(state);
            };

            state.finalized = true;
            const written = w.buffered();
            if (written.len == 0) return null;
            self.total_decompressed +|= written.len;
            if (self.total_decompressed > self.limits.max_decompressed_size) return error.DecompressionBombDetected;
            return written;
        }

        fn refillFlateAndRetry(self: *Self, state: *FlateDecompressorState) !?[]const u8 {
            const new_data = self.reader.readSliceShort(state.input_buf[state.input_len..]) catch return null;
            if (new_data == 0) {
                state.finalized = true;
                return null;
            }
            state.input_len += new_data;
            self.total_compressed +|= new_data;

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
            if (written.len == 0) return null;
            self.total_decompressed +|= written.len;
            if (self.total_decompressed > self.limits.max_decompressed_size) return error.DecompressionBombDetected;
            return written;
        }

        // --- Brotli streaming (frame-aware accumulation) ---

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

            self.total_compressed +|= n;
            if (self.total_compressed > self.limits.max_compressed_input) return error.DecompressionBombDetected;

            try self.brotli_accum.?.appendSlice(self.allocator, buf[0..n]);

            if (self.decompressBrotli()) |result| return result;
            return self.readBrotliChunk();
        }

        fn decompressBrotli(self: *Self) ?[]const u8 {
            const accum = self.brotli_accum orelse return null;
            if (accum.items.len == 0) return null;

            const decompressed = brotli.decompress(self.allocator, accum.items) catch return null;
            self.brotli_accum.?.clearRetainingCapacity();

            self.total_decompressed +|= decompressed.len;
            if (self.total_decompressed > self.limits.max_decompressed_size) {
                self.allocator.free(decompressed);
                return null;
            }

            const owned = self.allocator.dupe(u8, decompressed) catch {
                self.allocator.free(decompressed);
                return null;
            };
            self.allocator.free(decompressed);
            return owned;
        }

        // --- Zstd streaming (frame-aware accumulation) ---

        fn readZstdChunk(self: *Self) !?[]const u8 {
            if (self.zstd_accum == null) {
                self.zstd_accum = .empty;
            }
            if (self.zstd_finalized) return null;

            var buf: [8192]u8 = undefined;
            const n = self.reader.readSliceShort(&buf) catch return null;
            if (n == 0) {
                self.zstd_finalized = true;
                return self.decompressZstdChunk();
            }

            self.total_compressed +|= n;
            if (self.total_compressed > self.limits.max_compressed_input) return error.DecompressionBombDetected;

            try self.zstd_accum.?.appendSlice(self.allocator, buf[0..n]);

            if (self.decompressZstdChunk()) |result| return result;
            return self.readZstdChunk();
        }

        fn decompressZstdChunk(self: *Self) ?[]const u8 {
            const accum = self.zstd_accum orelse return null;
            if (accum.items.len == 0) return null;

            const content_size = switch (zstd_pkg.getFrameContentSize(accum.items)) {
                .unknown, .@"error" => return null,
                .known => |s| s,
            };

            if (content_size > self.limits.max_decompressed_size) return null;

            const decompressed = zstd_pkg.decompress(self.allocator, accum.items, @intCast(content_size)) catch return null;
            self.zstd_accum.?.clearRetainingCapacity();

            self.total_decompressed +|= decompressed.len;
            return decompressed;
        }
    };
}

pub const StreamingCompressor = struct {
    allocator: Allocator,
    encoding: ContentEncoding,
    aw: std.Io.Writer.Allocating,
    flate_compressor: ?flate_comp_state = null,
    window_buf: [std.compress.flate.max_window_len]u8,
    total_input: usize = 0,
    limits: StreamingLimits,
    level: compression.CompressionLevel,

    const flate_comp_state = struct {
        compressor: std.compress.flate.Compress,
    };

    pub fn init(allocator: Allocator, encoding: ContentEncoding) StreamingCompressor {
        return .{
            .allocator = allocator,
            .encoding = encoding,
            .aw = .init(allocator),
            .flate_compressor = null,
            .window_buf = undefined,
            .limits = .{},
            .level = .default,
        };
    }

    pub fn initWithOptions(allocator: Allocator, encoding: ContentEncoding, level: compression.CompressionLevel, limits: StreamingLimits) StreamingCompressor {
        return .{
            .allocator = allocator,
            .encoding = encoding,
            .aw = .init(allocator),
            .flate_compressor = null,
            .window_buf = undefined,
            .limits = limits,
            .level = level,
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
                const flate_level = switch (self.level) {
                    .fast => std.compress.flate.Compress.Options.level_1,
                    .default => std.compress.flate.Compress.Options.level_6,
                    .best => std.compress.flate.Compress.Options.level_9,
                };
                const compressor = std.compress.flate.Compress.init(
                    &self.aw.writer,
                    &self.window_buf,
                    container,
                    flate_level,
                ) catch return error.CompressionFailed;
                self.flate_compressor = .{ .compressor = compressor };
            },
            .br, .zstd => {},
        }
    }

    pub fn writeChunk(self: *StreamingCompressor, chunk: []const u8) !void {
        if (chunk.len == 0) return;

        self.total_input +|= chunk.len;
        if (self.total_input > self.limits.max_compressed_input) return error.CompressionLimitExceeded;

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
                const compressed = brotli.compress(self.allocator, chunk) catch return error.CompressionFailed;
                defer self.allocator.free(compressed);
                _ = self.aw.writer.writeAll(compressed) catch return error.IoFailed;
            },
            .zstd => {
                const zstd_level: i32 = switch (self.level) {
                    .fast => 1,
                    .default => 3,
                    .best => 19,
                };
                const compressed = zstd_pkg.compress(self.allocator, chunk, zstd_level) catch return error.CompressionFailed;
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

    pub fn getWritten(self: *const StreamingCompressor) []const u8 {
        return self.aw.getWritten();
    }

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

test "streaming decompressor brotli round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Hello, streaming decompression test with brotli encoding! This is a longer string to test accumulation.";
    const compressed = try compression.compress(allocator, .br, sample);
    defer allocator.free(compressed);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .br, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        defer allocator.free(chunk);
        try result.appendSlice(allocator, chunk);
    }

    try testing.expectEqualStrings(sample, result.items);
}

test "streaming decompressor zstd round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Hello, streaming decompression test with zstd encoding! Another longer string.";
    const compressed = try compression.compress(allocator, .zstd, sample);
    defer allocator.free(compressed);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).init(allocator, .zstd, r);
    defer decompressor.deinit();

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    while (try decompressor.readChunk()) |chunk| {
        defer allocator.free(chunk);
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

test "streaming decompressor bomb protection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample = "Bomb test data";
    const compressed = try compression.compress(allocator, .gzip, sample);
    defer allocator.free(compressed);

    const r: std.Io.Reader = .fixed(compressed);
    var decompressor = StreamingDecompressor(std.Io.Reader).initWithLimits(allocator, .gzip, r, .{
        .max_decompressed_size = 5,
    });
    defer decompressor.deinit();

    const result = decompressor.readChunk();
    try testing.expectError(error.DecompressionBombDetected, result);
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
