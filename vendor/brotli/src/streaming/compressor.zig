//! Streaming Brotli compressor.
//!
//! Provides incremental compression supporting both memory-slice feeds
//! and direct streaming to standard Zig `std.Io.Writer` interfaces.

const std = @import("std");
const encoder = @import("../compress/encode.zig");

pub const Options = encoder.Options;
pub const CompressionOptions = encoder.Options;
pub const Encoder = encoder.Encoder;
pub const ProgressCallback = encoder.ProgressCallback;
pub const SharedDictionary = encoder.SharedDictionary;
pub const SharedDictionaryType = encoder.SharedDictionaryType;

/// Streaming and incremental compression context over the native Brotli encoder.
///
/// Supports direct I/O writing with `std.Io.Writer` as well as chunked memory
/// slice operations without requiring full input pre-buffering.
pub const StreamingCompressor = struct {
    inner: Encoder,
    err: ?anyerror = null,

    /// Initializes a streaming compressor with the provided allocator and options.
    pub fn init(allocator: std.mem.Allocator, options: CompressionOptions) StreamingCompressor {
        return .{ .inner = Encoder.init(allocator, options) };
    }

    /// Releases all resources owned by the compressor.
    pub fn deinit(self: *StreamingCompressor) void {
        self.inner.deinit();
    }

    /// Resets the streaming compressor for reuse with new options without reallocating workspaces.
    pub fn reset(self: *StreamingCompressor, options: CompressionOptions) void {
        self.err = null;
        self.inner.reset(options);
    }

    /// Registers an optional progress callback.
    pub fn setProgress(self: *StreamingCompressor, cb: ?ProgressCallback, ctx: ?*anyopaque) void {
        self.inner.setProgress(cb, ctx);
    }

    /// Attaches a custom dictionary; must precede the first write/process call.
    pub fn attachDictionary(self: *StreamingCompressor, data: []const u8) bool {
        return self.inner.attachDictionary(data);
    }

    /// Attaches a shared dictionary containing compound prefix chunks; must precede the first write/process call.
    pub fn attachSharedDictionary(self: *StreamingCompressor, dict: *const SharedDictionary) bool {
        return self.inner.attachSharedDictionary(dict);
    }

    /// Streams an input chunk directly into a `std.Io.Writer`.
    pub fn write(self: *StreamingCompressor, chunk: []const u8, writer: *std.Io.Writer) !void {
        self.inner.compressStream(.process, chunk) catch |e| {
            self.err = e;
            return e;
        };
        const n = self.inner.out.items.len - self.inner.out_pos;
        if (n > 0) {
            try writer.writeAll(self.inner.out.items[self.inner.out_pos..]);
            self.inner.out_pos = self.inner.out.items.len;
        }
    }

    /// Flushes pending input directly into a `std.Io.Writer`.
    pub fn flush(self: *StreamingCompressor, writer: *std.Io.Writer) !void {
        self.inner.compressStream(.flush, null) catch |e| {
            self.err = e;
            return e;
        };
        const n = self.inner.out.items.len - self.inner.out_pos;
        if (n > 0) {
            try writer.writeAll(self.inner.out.items[self.inner.out_pos..]);
            self.inner.out_pos = self.inner.out.items.len;
        }
    }

    /// Finishes the stream, writing the final meta-block directly to `std.Io.Writer`.
    pub fn finish(self: *StreamingCompressor, writer: *std.Io.Writer) !void {
        if (!self.inner.isFinished()) {
            self.inner.compressStream(.finish, null) catch |e| {
                self.err = e;
                return e;
            };
        }
        const n = self.inner.out.items.len - self.inner.out_pos;
        if (n > 0) {
            try writer.writeAll(self.inner.out.items[self.inner.out_pos..]);
            self.inner.out_pos = self.inner.out.items.len;
        }
    }

    /// Memory API: pushes one input chunk, returning any newly compressed bytes.
    /// The caller owns the returned slice.
    pub fn process(self: *StreamingCompressor, chunk: []const u8) ![]u8 {
        self.inner.compressStream(.process, chunk) catch |e| {
            self.err = e;
            return e;
        };
        return self.drain();
    }

    /// Memory API: flushes pending input into complete blocks and returns the slice.
    pub fn flushAlloc(self: *StreamingCompressor) ![]u8 {
        self.inner.compressStream(.flush, null) catch |e| {
            self.err = e;
            return e;
        };
        return self.drain();
    }

    /// Memory API: finishes the stream and returns the final compressed bytes.
    pub fn finishAlloc(self: *StreamingCompressor) ![]u8 {
        if (!self.inner.isFinished()) {
            self.inner.compressStream(.finish, null) catch |e| {
                self.err = e;
                return e;
            };
        }
        return self.drain();
    }

    /// Emits a metadata metablock (RFC 7932 section 9.2) carrying `payload`.
    pub fn emitMetadata(self: *StreamingCompressor, payload: []const u8) ![]u8 {
        self.inner.compressStream(.emit_metadata, payload) catch |e| {
            self.err = e;
            return e;
        };
        return self.drain();
    }

    /// Returns true if the compression stream is complete and closed.
    pub fn isFinished(self: *const StreamingCompressor) bool {
        return self.inner.isFinished();
    }

    fn drain(self: *StreamingCompressor) ![]u8 {
        const n = self.inner.out.items.len - self.inner.out_pos;
        if (n == 0) return &.{};
        const copy = try self.inner.allocator.alloc(u8, n);
        const taken = self.inner.takeOutput(copy);
        std.debug.assert(taken == n);
        return copy;
    }
};

/// Compresses from a `std.Io.Reader` directly to a `std.Io.Writer` using chunked streaming.
pub fn compressStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: CompressionOptions,
) !void {
    var sc = StreamingCompressor.init(allocator, options);
    defer sc.deinit();

    var buf: [16384]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch |err| return err;
        if (n == 0) break;
        try sc.write(buf[0..n], writer);
    }
    try sc.finish(writer);
}

// Unit Tests
const testing = std.testing;

test "StreamingCompressor basic lifecycle" {
    var sc = StreamingCompressor.init(testing.allocator, .{ .quality = 1 });
    defer sc.deinit();

    const chunk1 = try sc.process("streaming unit test chunk 1 ");
    defer testing.allocator.free(chunk1);

    const chunk2 = try sc.process("streaming unit test chunk 2");
    defer testing.allocator.free(chunk2);

    const tail = try sc.finishAlloc();
    defer testing.allocator.free(tail);

    try testing.expect(sc.isFinished());
}

test "StreamingCompressor reset and reuse" {
    var sc = StreamingCompressor.init(testing.allocator, .{ .quality = 2 });
    defer sc.deinit();

    const out1 = try sc.finishAlloc();
    defer testing.allocator.free(out1);
    try testing.expect(sc.isFinished());

    sc.reset(.{ .quality = 4 });
    try testing.expect(!sc.isFinished());

    const out2 = try sc.finishAlloc();
    defer testing.allocator.free(out2);
    try testing.expect(sc.isFinished());
}

test "StreamingCompressor 1-byte chunks and finish" {
    var sc = StreamingCompressor.init(testing.allocator, .{ .quality = 4 });
    defer sc.deinit();

    const msg = "Streaming byte by byte through StreamingCompressor!";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    for (msg) |b| {
        const chunk = try sc.process(&.{b});
        defer testing.allocator.free(chunk);
        if (chunk.len > 0) try out.appendSlice(testing.allocator, chunk);
    }

    const tail = try sc.finishAlloc();
    defer testing.allocator.free(tail);
    if (tail.len > 0) try out.appendSlice(testing.allocator, tail);

    try testing.expect(sc.isFinished());
    try testing.expect(out.items.len > 0);
}

test "StreamingCompressor attachSharedDictionary" {
    var dict = SharedDictionary.init(testing.allocator);
    defer dict.deinit();
    const prefix_data = "https://example.com/api/v1/resource/";
    _ = dict.attach(.raw, prefix_data);

    var sc = StreamingCompressor.init(testing.allocator, .{ .quality = 5 });
    defer sc.deinit();
    try testing.expect(sc.attachSharedDictionary(&dict));

    const chunk = try sc.process("12345/details");
    defer testing.allocator.free(chunk);
    const tail = try sc.finishAlloc();
    defer testing.allocator.free(tail);
    try testing.expect(sc.isFinished());
}
