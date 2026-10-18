//! Streaming Brotli decompressor.
//!
//! Provides incremental decompression supporting both chunked memory feeds
//! and direct streaming with standard Zig `std.Io.Reader` and `std.Io.Writer`.

const std = @import("std");
const decoder = @import("../decompress/decode.zig");

pub const Options = decoder.Options;
pub const DecompressionOptions = decoder.Options;
pub const Decoder = decoder.Decoder;
pub const DecodeResult = decoder.Result;
pub const ErrorCode = decoder.ErrorCode;
pub const SharedDictionary = decoder.SharedDictionary;
pub const SharedDictionaryType = decoder.SharedDictionaryType;

/// Incremental streaming decompression context over the native Brotli decoder.
///
/// Supports arbitrary byte-boundary feeding without requiring the full compressed
/// stream to be present in memory.
pub const StreamingDecompressor = struct {
    inner: Decoder,
    allocator: std.mem.Allocator,
    inbuf: std.ArrayList(u8),
    fed_pos: usize = 0,
    finished_: bool = false,
    /// Set by `endInput`: no more bytes will ever be fed. Lets `take` tell
    /// a truncated stream (decoder still needs input) apart from a stream
    /// that is merely waiting for the next chunk.
    input_ended: bool = false,

    /// Initializes a streaming decompressor with the provided allocator and options.
    pub fn init(allocator: std.mem.Allocator, options: DecompressionOptions) StreamingDecompressor {
        return .{
            .inner = Decoder.init(allocator, options),
            .allocator = allocator,
            .inbuf = .empty,
        };
    }

    /// Releases all resources owned by the decompressor.
    pub fn deinit(self: *StreamingDecompressor) void {
        self.inbuf.deinit(self.allocator);
        self.inner.deinit();
    }

    /// Resets the streaming decompressor for reuse with new options without reallocating ringbuffers.
    pub fn reset(self: *StreamingDecompressor, options: DecompressionOptions) void {
        self.inbuf.clearRetainingCapacity();
        self.fed_pos = 0;
        self.finished_ = false;
        self.input_ended = false;
        self.inner.reset(options);
    }

    /// Attaches a custom dictionary; must precede the first feed/read call.
    pub fn attachDictionary(self: *StreamingDecompressor, data: []const u8) bool {
        return self.inner.attachDictionary(data);
    }

    /// Attaches a shared dictionary containing compound prefix chunks; must precede the first feed/read call.
    pub fn attachSharedDictionary(self: *StreamingDecompressor, dict: *const SharedDictionary) bool {
        return self.inner.attachSharedDictionary(dict);
    }

    /// Feeds input bytes into the internal accumulation buffer.
    pub fn feed(self: *StreamingDecompressor, chunk: []const u8) !void {
        try self.inbuf.appendSlice(self.allocator, chunk);
    }

    /// Signals no more input will arrive; flushes any remaining partial data.
    pub fn endInput(self: *StreamingDecompressor) void {
        self.input_ended = true;
        var empty: []const u8 = &.{};
        var avail: []u8 = &.{};
        _ = self.inner.decompressStream(&empty, &avail, null);
    }

    /// Decodes into `out`; returns bytes written during this call.
    /// Callers should continue invoking until both `isFinished()` and zero output returned.
    /// Call `endInput()` after the last `feed`; once ended, a stream that still
    /// needs input is truncated and `take` reports `error.TruncatedInput`
    /// instead of stalling with zero bytes forever.
    pub fn take(self: *StreamingDecompressor, out: []u8) !usize {
        var avail: []u8 = out;
        const total_before = self.inner.partial_pos_out;
        var needs_input = false;

        // Feed unconsumed buffered input.
        var unconsumed: []const u8 = self.inbuf.items[self.fed_pos..];
        if (unconsumed.len > 0) {
            const r = self.inner.decompressStream(&unconsumed, &avail, &self.inner.partial_pos_out);
            self.fed_pos = self.inbuf.items.len - unconsumed.len;
            switch (r) {
                .success => self.finished_ = true,
                .needs_more_input => needs_input = true,
                .needs_more_output => {},
                .err => return error.BrotliStreamError,
            }
            if (self.fed_pos > 0) {
                const rem = self.inbuf.items.len - self.fed_pos;
                std.mem.copyForwards(u8, self.inbuf.items[0..rem], self.inbuf.items[self.fed_pos..]);
                self.inbuf.shrinkRetainingCapacity(rem);
                self.fed_pos = 0;
            }
        }

        // Signal end-of-stream once all input has been absorbed.
        if (!self.finished_) {
            var empty: []const u8 = &.{};
            const r2 = self.inner.decompressStream(&empty, &avail, &self.inner.partial_pos_out);
            switch (r2) {
                .success => self.finished_ = true,
                .needs_more_input => needs_input = true,
                .needs_more_output => {},
                .err => return error.BrotliStreamError,
            }
        }

        // No buffered input remains, no more is coming, and the decoder still
        // wants bytes: the stream is truncated. Fail explicitly rather than
        // reporting zero progress forever.
        if (!self.finished_ and self.input_ended and self.inbuf.items.len == 0 and needs_input) {
            return error.TruncatedInput;
        }

        return @intCast(self.inner.partial_pos_out - total_before);
    }

    /// Reads from a `std.Io.Reader` and writes decompressed bytes to a `std.Io.Writer`.
    pub fn read(self: *StreamingDecompressor, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var in_chunk: [16384]u8 = undefined;
        var out_chunk: [16384]u8 = undefined;

        while (!self.isFinished()) {
            const n_in = reader.readSliceShort(&in_chunk) catch |err| return err;
            if (n_in > 0) {
                try self.feed(in_chunk[0..n_in]);
            } else {
                self.endInput();
            }

            while (true) {
                const n_out = try self.take(&out_chunk);
                if (n_out > 0) {
                    try writer.writeAll(out_chunk[0..n_out]);
                }
                if (n_out == 0) break;
            }

            if (n_in == 0 and !self.isFinished()) {
                if (self.hasError()) return self.errorCode().toError();
                break;
            }
        }
    }

    /// Returns true if decompression has completed successfully.
    pub fn isFinished(self: *const StreamingDecompressor) bool {
        return self.finished_;
    }

    /// Returns true if a decoding error was recorded.
    pub fn hasError(self: *const StreamingDecompressor) bool {
        return self.inner.errorCode().isError();
    }

    /// Returns the diagnostic error code from the underlying decoder.
    pub fn errorCode(self: *const StreamingDecompressor) ErrorCode {
        return self.inner.errorCode();
    }

    /// Returns the cumulative number of bytes written so far.
    pub fn totalOut(self: *const StreamingDecompressor) u64 {
        return self.inner.partial_pos_out;
    }
};

/// Decompresses from `std.Io.Reader` directly to `std.Io.Writer` with streaming buffers.
pub fn decompressStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: DecompressionOptions,
) !void {
    var dec = Decoder.init(allocator, options);
    defer dec.deinit();

    var in_buf: [16384]u8 = undefined;
    var out_buf: [16384]u8 = undefined;
    var in_slice: []const u8 = &.{};
    var total_out: u64 = 0;

    var eof = false;
    while (true) {
        if (in_slice.len == 0 and !eof) {
            const n_read = reader.readSliceShort(&in_buf) catch |err| return err;
            if (n_read == 0) {
                eof = true;
                in_slice = &.{};
            } else {
                in_slice = in_buf[0..n_read];
            }
        }

        var avail_out: []u8 = &out_buf;
        const result = dec.decompressStream(&in_slice, &avail_out, &total_out);
        const produced = out_buf.len - avail_out.len;
        if (produced > 0) {
            try writer.writeAll(out_buf[0..produced]);
        }

        switch (result) {
            .success => return,
            .needs_more_output => continue,
            .needs_more_input => {
                if (eof) {
                    if (dec.errorCode().isError()) return dec.errorCode().toError();
                    return error.TruncatedInput;
                }
                continue;
            },
            .err => return dec.errorCode().toError(),
        }
    }
}

// Unit Tests
const testing = std.testing;

test "StreamingDecompressor on empty finalized stream" {
    var sd = StreamingDecompressor.init(testing.allocator, .{});
    defer sd.deinit();
    try sd.feed(&.{0x06}); // Empty RFC 7932 stream
    var out: [16]u8 = undefined;
    const n = try sd.take(&out);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expect(sd.isFinished());
}

test "StreamingDecompressor reset and reuse" {
    var sd = StreamingDecompressor.init(testing.allocator, .{});
    defer sd.deinit();

    try sd.feed(&.{0x06});
    var out: [16]u8 = undefined;
    _ = try sd.take(&out);
    try testing.expect(sd.isFinished());

    sd.reset(.{});
    try testing.expect(!sd.isFinished());
    try sd.feed(&.{0x06});
    _ = try sd.take(&out);
    try testing.expect(sd.isFinished());
}

test "StreamingDecompressor 1-byte feed and 1-byte take" {
    var sd = StreamingDecompressor.init(testing.allocator, .{});
    defer sd.deinit();

    // Valid Brotli stream for "Xyzzy" (10 bytes)
    const stream = "\x0b\x02\x80\x58\x79\x7a\x7a\x79\x03";
    for (stream) |b| {
        try sd.feed(&.{b});
    }
    sd.endInput();

    var out_buf: [1]u8 = undefined;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(testing.allocator);

    while (!sd.isFinished()) {
        const n = try sd.take(&out_buf);
        if (n > 0) {
            try result.appendSlice(testing.allocator, out_buf[0..n]);
        }
        if (n == 0 and sd.hasError()) return error.BrotliStreamError;
    }

    try testing.expectEqualStrings("Xyzzy", result.items);
}

test "StreamingDecompressor attachSharedDictionary" {
    var dict = SharedDictionary.init(testing.allocator);
    defer dict.deinit();
    _ = dict.attach(.raw, "prefix_dictionary_content");

    var sd = StreamingDecompressor.init(testing.allocator, .{});
    defer sd.deinit();
    try testing.expect(sd.attachSharedDictionary(&dict));

    try sd.feed(&.{0x06});
    var out: [16]u8 = undefined;
    _ = try sd.take(&out);
    try testing.expect(sd.isFinished());
}

test "StreamingDecompressor reports truncation instead of stalling" {
    // A truncated stream with endInput() must fail explicitly. Without the
    // end-of-input check, a take()-until-finished loop spins forever on zero
    // progress because the decoder keeps reporting needs_more_input.
    const encoder = @import("../compress/encode.zig");
    const payload = "streaming truncation must fail explicitly, never stall the caller";
    const comp = try encoder.compressWithOptions(testing.allocator, payload, .{ .quality = 5 });
    defer testing.allocator.free(comp);

    var sd = StreamingDecompressor.init(testing.allocator, .{});
    defer sd.deinit();
    // Feed only the first half, then end the input.
    try sd.feed(comp[0 .. comp.len / 2]);
    sd.endInput();

    var out: [64]u8 = undefined;
    var calls: usize = 0;
    while (!sd.isFinished()) {
        calls += 1;
        try testing.expect(calls < 1000);
        const n = sd.take(&out) catch |e| {
            try testing.expectEqual(error.TruncatedInput, e);
            return;
        };
        _ = n;
    }
    // A halved stream must never decode to completion.
    return error.TruncatedStreamAccepted;
}
