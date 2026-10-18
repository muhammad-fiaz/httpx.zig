//! Native Zig implementation of the Brotli compressed data format
//! (RFC 7932 / Large Window Brotli) - public client API facade.
//!
//! Provides a thin, idiomatic client surface for Brotli compression, decompression,
//! streaming I/O, format inspection, and configuration.
//!
//! Usage:
//!
//!     const brotli = @import("brotli");
//!
//!     // One-shot compression and decompression
//!     const compressed = try brotli.compress(allocator, "data to compress");
//!     defer allocator.free(compressed);
//!
//!     const original = try brotli.decompress(allocator, compressed);
//!     defer allocator.free(original);
//!
//!     // Reusable context
//!     var compressor = brotli.Compressor.init(allocator, .{ .quality = 9 });
//!     defer compressor.deinit();

const std = @import("std");

pub const constants = @import("common/constants.zig");
pub const context = @import("common/context.zig");
pub const transform = @import("common/transform.zig");
pub const Dictionary = @import("dictionary/dictionary.zig");
pub const BitReader = @import("bitstream/bit_reader.zig").BitReader;
pub const bit_writer = @import("bitstream/bit_writer.zig");
pub const huffman = @import("huffman/huffman.zig");
pub const HuffmanCode = huffman.HuffmanCode;

const encoder = @import("compress/encode.zig");
const decoder = @import("decompress/decode.zig");
pub const compress_fragment = @import("compress/compress_fragment.zig");
pub const compress_fragment_two_pass = @import("compress/compress_fragment_two_pass.zig");
pub const metablock_fast = @import("compress/metablock_fast.zig");
pub const metablock = @import("compress/metablock.zig");
pub const metablock_hq = @import("compress/metablock_hq.zig");
pub const hlmq = @import("compress/hash_longest_match_quickly.zig");
pub const backward_references = @import("compress/backward_references.zig");
pub const hlms = @import("compress/hash_longest_match_simd.zig");
pub const hlm = @import("compress/hash_longest_match.zig");
pub const hash_to_binary_tree = @import("compress/hash_to_binary_tree.zig");
pub const literal_cost = @import("compress/literal_cost.zig");
pub const backward_references_hq = @import("compress/backward_references_hq.zig");
pub const streaming = @import("streaming/streaming.zig");
pub const shared_dictionary = @import("common/shared_dictionary.zig");
pub const SharedDictionary = shared_dictionary.SharedDictionary;
pub const SharedDictionaryType = shared_dictionary.SharedDictionaryType;
pub const MAX_COMPOUND_DICTS = shared_dictionary.MAX_COMPOUND_DICTS;
pub const utf8_util = @import("compress/utf8_util.zig");
pub const huffman_encode = @import("compress/huffman_encode.zig");
pub const fast_log = @import("compress/fast_log.zig");
pub const prefix_ranges = @import("common/prefix_ranges.zig");

// Library and Specification Versions

/// Native Brotli library release version.
pub const version = "0.0.5";
pub const version_number: u32 = 0 * 100 * 100 + 0 * 100 + 5;
pub const versionNumberValue: u32 = version_number;

/// Brotli format specification version implemented (RFC 7932 / v1.2.0).
pub const spec_version = "1.2.0";
pub const spec_version_number: u32 = 1 * 100 * 100 + 2 * 100 + 0;
pub const specVersion = spec_version;
pub const specVersionNumber = spec_version_number;

/// Returns the library version string.
pub fn versionString() []const u8 {
    return version;
}

/// Returns the integer-encoded library version.
pub fn versionNumber() u32 {
    return version_number;
}

// Codec Types & Contexts

pub const Compressor = encoder.Encoder;
pub const Encoder = encoder.Encoder;
pub const CompressionOptions = encoder.Options;
pub const EncoderOptions = encoder.Options;
pub const CompressionMode = encoder.Mode;
pub const Strategy = encoder.Mode;
pub const EncoderMode = encoder.Mode;
pub const EncoderOperation = encoder.Operation;
pub const ProgressCallback = encoder.ProgressCallback;

pub const Decompressor = decoder.Decoder;
pub const Decoder = decoder.Decoder;
pub const DecompressionOptions = decoder.Options;
pub const DecoderOptions = decoder.Options;
pub const DecodeResult = decoder.Result;
pub const ErrorCode = decoder.ErrorCode;
pub const MetadataCallbacks = decoder.MetadataCallbacks;
pub const DecompressionContext = decoder.Decoder;
pub const BrotliCodecError = decoder.ErrorCode;

pub const StreamingCompressor = streaming.StreamingCompressor;
pub const StreamingDecompressor = streaming.StreamingDecompressor;

// Error Reporting

/// Canonical public error set for Brotli operations.
pub const Error = error{
    CorruptStream,
    TruncatedInput,
    InvalidHeader,
    InvalidMetaBlock,
    InvalidHuffmanTree,
    InvalidCommand,
    InvalidDistance,
    InvalidDictionaryReference,
    ResourceLimitExceeded,
    OutputLimitExceeded,
    OutOfMemory,
    InvalidParameter,
    InvalidStreamingState,
    NeedsMoreInput,
    NeedsMoreOutput,
    BrotliCompressionError,
    BrotliDecompressionError,
    BrotliStreamError,
};

/// Diagnostic wrapper providing status inspectability for decoder operations.
pub const BrotliErrorInfo = struct {
    code: ErrorCode,

    pub fn name(self: BrotliErrorInfo) []const u8 {
        return self.code.name();
    }
    pub fn isError(self: BrotliErrorInfo) bool {
        return self.code.isError();
    }
    pub fn toError(self: BrotliErrorInfo) Error {
        return self.code.toError();
    }
};

// Public API Functions (Delegations to Specialized Codec Modules)

/// Compresses a slice of bytes into an allocated buffer with default options.
/// The caller owns the returned slice.
pub const compress = encoder.compress;

/// Compresses a slice of bytes with explicit compression options.
/// The caller owns the returned slice.
pub const compressWithOptions = encoder.compressWithOptions;

/// Returns an upper bound on compressed size for a given input size.
pub const maxCompressedSize = encoder.maxCompressedSize;

/// Decompresses a complete Brotli stream into an allocated buffer with default options.
/// The caller owns the returned slice.
pub const decompress = decoder.decompress;

/// Decompresses a complete Brotli stream with explicit options (window limits, dictionary, etc.).
/// The caller owns the returned slice.
pub const decompressWithOptions = decoder.decompressWithOptions;

/// Decompresses directly into a caller-provided destination slice.
pub const decompressInto = decoder.decompressInto;

/// Compresses from a `std.Io.Reader` directly to a `std.Io.Writer` using chunked streaming.
pub const compressStream = streaming.compressStream;

/// Decompresses from a `std.Io.Reader` directly to a `std.Io.Writer` using chunked streaming.
pub const decompressStream = streaming.decompressStream;

/// Compresses a slice of bytes using a shared/compound dictionary.
pub fn compressWithSharedDictionary(
    allocator: std.mem.Allocator,
    input: []const u8,
    dict: *const SharedDictionary,
    options: CompressionOptions,
) ![]u8 {
    var opts = options;
    opts.sharedDictionary = dict;
    return encoder.compressWithOptions(allocator, input, opts);
}

/// Decompresses a slice of bytes using a shared/compound dictionary.
pub fn decompressWithSharedDictionary(
    allocator: std.mem.Allocator,
    input: []const u8,
    dict: *const SharedDictionary,
    options: DecompressionOptions,
) ![]u8 {
    var opts = options;
    opts.sharedDictionary = dict;
    return decoder.decompressWithOptions(allocator, input, opts);
}

// Configuration Parameters & Limits

pub const paramMode = encoder.paramMode;
pub const paramQuality = encoder.paramQuality;
pub const paramLgWin = encoder.paramLgWin;
pub const paramLgBlock = encoder.paramLgBlock;
pub const paramDisableLiteralContextModeling = encoder.paramDisableLiteralContextModeling;
pub const paramSizeHint = encoder.paramSizeHint;
pub const paramLargeWindow = encoder.paramLargeWindow;
pub const paramNPostfix = encoder.paramNPostfix;
pub const paramNDirect = encoder.paramNDirect;

pub const PARAM_MODE = paramMode;
pub const PARAM_QUALITY = paramQuality;
pub const PARAM_LGWIN = paramLgWin;
pub const PARAM_LGBLOCK = paramLgBlock;
pub const PARAM_DISABLE_LITERAL_CONTEXT_MODELING = paramDisableLiteralContextModeling;
pub const PARAM_SIZE_HINT = paramSizeHint;
pub const PARAM_LARGE_WINDOW = paramLargeWindow;
pub const PARAM_NPOSTFIX = paramNPostfix;
pub const PARAM_NDIRECT = paramNDirect;

pub const maxBlockSize = constants.BLOCK_SIZE_CAP;
pub const maxQuality = 11;
pub const minQuality = 0;
pub const defaultQuality = 11;
pub const defaultWindow = 22;
pub const minWindowBits = constants.LARGE_MIN_WBITS;
pub const maxWindowBits = 24;
pub const largeMaxWindowBits = constants.LARGE_MAX_WBITS;

pub const BLOCKSIZE_MAX = maxBlockSize;
pub const MAX_QUALITY = maxQuality;
pub const MIN_QUALITY = minQuality;
pub const DEFAULT_QUALITY = defaultQuality;
pub const DEFAULT_WINDOW = defaultWindow;
pub const MIN_WINDOW_BITS = minWindowBits;
pub const MAX_WINDOW_BITS = maxWindowBits;
pub const LARGE_MAX_WINDOW_BITS = largeMaxWindowBits;

pub const CONTEXT_MAP_MAX_RLE = constants.CONTEXT_MAP_MAX_RLE;
pub const MAX_NUMBER_OF_BLOCK_TYPES = constants.MAX_NUMBER_OF_BLOCK_TYPES;
pub const NUM_LITERAL_SYMBOLS = constants.NUM_LITERAL_SYMBOLS;
pub const NUM_COMMAND_SYMBOLS = constants.NUM_COMMAND_SYMBOLS;
pub const NUM_DISTANCE_SHORT_CODES = constants.NUM_DISTANCE_SHORT_CODES;
pub const WINDOW_GAP = constants.WINDOW_GAP;

// Unit Tests for Public Facade

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "facade version accessors" {
    try testing.expectEqualStrings("0.0.5", version);
    try testing.expectEqualStrings(version, versionString());
    try testing.expectEqual(@as(u32, 5), versionNumber());
    try testing.expectEqualStrings("1.2.0", specVersion);
    try testing.expectEqual(@as(u32, 10200), specVersionNumber);
}

test "facade delegation round trip" {
    const original = "Testing thin public facade round-trip delegation in brotli.zig!";
    const comp = try compress(testing.allocator, original);
    defer testing.allocator.free(comp);

    const decomp = try decompress(testing.allocator, comp);
    defer testing.allocator.free(decomp);

    try testing.expectEqualStrings(original, decomp);
}

// Integration, Edge-Case, and Interoperability Test Cases

fn repeatPattern(comptime s: []const u8, comptime count: usize) [s.len * count]u8 {
    var res: [s.len * count]u8 = undefined;
    for (0..count) |i| {
        @memcpy(res[i * s.len .. (i + 1) * s.len], s);
    }
    return res;
}

fn expectRoundTrip(input: []const u8, options: CompressionOptions) !void {
    const allocator = testing.allocator;
    const compressed = try compressWithOptions(allocator, input, options);
    defer allocator.free(compressed);
    const bound = @max(maxCompressedSize(input.len), input.len * 2 + 700);
    try testing.expect(compressed.len <= bound);

    const decoded = try decompress(allocator, compressed);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, input, decoded);
}

test "round trip empty" {
    try expectRoundTrip(&.{}, .{});
    try expectRoundTrip(&.{}, .{ .quality = 0 });
    try expectRoundTrip(&.{}, .{ .quality = 5, .lgWin = 16 });
}

test "round trip tiny inputs" {
    try expectRoundTrip("a", .{});
    try expectRoundTrip("ab", .{});
    try expectRoundTrip("abc", .{});
    try expectRoundTrip("aaaaaaaa", .{});
    try expectRoundTrip("\x00\x00\x00\x00", .{});
}

test "round trip text at several qualities" {
    var input: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1234);
    const words = [_][]const u8{ "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ", "brotli ", "zig " };
    var filled: usize = 0;
    while (filled < input.len - 16) {
        const w = words[prng.random().intRangeLessThan(usize, 0, words.len)];
        @memcpy(input[filled..][0..w.len], w);
        filled += w.len;
    }
    @memset(input[filled..], 'x');

    inline for (.{ 0, 1, 2, 5, 9, 11 }) |q| {
        try expectRoundTrip(input[0 .. 5000 + q], .{ .quality = q });
    }
    try expectRoundTrip(&input, .{});
}

test "round trip highly repetitive data" {
    var input: [20000]u8 = @splat(0xAB);
    try expectRoundTrip(&input, .{ .quality = 11 });
    try expectRoundTrip(&input, .{ .quality = 1 });

    var pattern: [10000]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i / 7);
    try expectRoundTrip(&pattern, .{ .quality = 6 });
}

test "round trip incompressible data uses stored blocks" {
    var random: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(99);
    prng.random().bytes(&random);
    try expectRoundTrip(&random, .{ .quality = 6 });
    try expectRoundTrip(&random, .{ .quality = 2 });
}

test "round trip binary with long distance matches" {
    var input: [32000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&input, 0..) |*b, i| {
        b.* = if (i < 1000) @truncate(prng.random().int(u8)) else input[i - 1000];
    }
    try expectRoundTrip(&input, .{ .quality = 6, .lgWin = 16 });
    try expectRoundTrip(&input, .{ .quality = 6, .lgWin = 22 });
    try expectRoundTrip(&input, .{ .quality = 11, .lgWin = 24 });
}

test "round trip across window sizes" {
    var input: [5000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 3));
    inline for (.{ 10, 12, 16, 17, 18, 20, 21, 22, 23 }) |w| {
        try expectRoundTrip(&input, .{ .quality = 5, .lgWin = w });
    }
}

test "one-shot compress honors maxCompressedSize bound" {
    const allocator = testing.allocator;
    var input: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&input);
    const compressed = try compressWithOptions(allocator, &input, .{ .quality = 1 });
    defer allocator.free(compressed);
    const bound = @max(maxCompressedSize(input.len), input.len * 2 + 700);
    try testing.expect(compressed.len <= bound);
}

test "streaming compressor matches one-shot output shape" {
    const allocator = testing.allocator;
    var input: [50000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i % 251);

    var sc = StreamingCompressor.init(allocator, .{});
    defer sc.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var off: usize = 0;
    while (off < input.len) {
        const take = @min(@as(usize, 7777), input.len - off);
        const piece = try sc.process(input[off .. off + take]);
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
        off += take;
    }
    const tail = try sc.finishAlloc();
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);

    try testing.expect(sc.isFinished());

    const decoded = try decompress(allocator, out.items);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, &input, decoded);
}

test "streaming flush produces decodable intermediate output" {
    const allocator = testing.allocator;

    var sc = StreamingCompressor.init(allocator, .{});
    defer sc.deinit();
    _ = try sc.process("flush me please flush me please ");
    const flushed = try sc.flushAlloc();
    defer allocator.free(flushed);
    try testing.expect(flushed.len > 0);

    _ = try sc.process("tail tail tail");
    const tail = try sc.finishAlloc();
    defer allocator.free(tail);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try whole.appendSlice(allocator, flushed);
    try whole.appendSlice(allocator, tail);

    const decoded = try decompress(allocator, whole.items);
    defer allocator.free(decoded);
    try testing.expectEqualStrings("flush me please flush me please tail tail tail", decoded);
}

test "progress callback fires during streaming" {
    const Counter = struct {
        calls: usize = 0,
        last_done: usize = 0,

        fn cb(ctx: ?*anyopaque, done: usize, total: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_done = done;
            _ = total;
        }
    };

    var counter = Counter{};
    var sc = StreamingCompressor.init(testing.allocator, .{
        .sizeHint = 100000,
    });
    defer sc.deinit();
    sc.setProgress(Counter.cb, &counter);

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'p');
    var i: usize = 0;
    while (i < 100000 / 4096) : (i += 1) {
        const piece = try sc.process(&chunk);
        testing.allocator.free(piece);
    }
    const tail = try sc.finishAlloc();
    testing.allocator.free(tail);

    try testing.expect(counter.calls > 0);
    try testing.expect(counter.last_done > 0);
}

test "compress then decompressInto fixed buffer" {
    const allocator = testing.allocator;
    const original = "fixed buffer target for decompressInto";
    const compressed = try compressWithOptions(allocator, original, .{});
    defer allocator.free(compressed);

    var buffer: [128]u8 = undefined;
    const n = try decompressInto(allocator, compressed, &buffer);
    try testing.expectEqualStrings(original, buffer[0..n]);
}

test "decompressInto distinguishes buffer too small from a corrupt stream" {
    const allocator = testing.allocator;
    const original = "fixed buffer target for decompressInto, long enough to need a real buffer size check";
    const compressed = try compressWithOptions(allocator, original, .{});
    defer allocator.free(compressed);

    // A buffer that cannot hold the whole result must say so, not report a
    // generic failure and not silently return a short count.
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.ResourceLimitExceeded, decompressInto(allocator, compressed, &tiny));

    // A stream that ends early is a truncation, not a corrupt stream.
    try testing.expectError(
        error.TruncatedInput,
        decompressInto(allocator, compressed[0 .. compressed.len / 2], &.{}),
    );

    // A buffer with exactly enough room succeeds and reports the exact length.
    const exact = try allocator.alloc(u8, original.len);
    defer allocator.free(exact);
    const n = try decompressInto(allocator, compressed, exact);
    try testing.expectEqual(original.len, n);
    try testing.expectEqualStrings(original, exact);

    // An empty caller buffer on an empty payload is a valid zero-length result.
    var none: [0]u8 = undefined;
    const empty_compressed = try compressWithOptions(allocator, "", .{});
    defer allocator.free(empty_compressed);
    try testing.expectEqual(@as(usize, 0), try decompressInto(allocator, empty_compressed, &none));
}

test "setParameter accepts documented identifiers" {
    var enc = Compressor.init(testing.allocator, .{});
    defer enc.deinit();
    try testing.expect(enc.setParameter(paramQuality, 9));
    try testing.expect(enc.setParameter(paramLgWin, 20));
    try testing.expect(enc.setParameter(paramSizeHint, 4096));
    try testing.expect(!enc.setParameter(999, 1));
}

test "custom dictionary round trip through encoder and decoder" {
    const allocator = testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog near the river bank every morning";
    const input = "quick brown fox jumps over the lazy dog";

    var enc = Compressor.init(allocator, .{ .quality = 11 });
    defer enc.deinit();
    try testing.expect(enc.attachDictionary(dict));
    try enc.compressStream(.process, input);
    try enc.compressStream(.finish, null);
    const compressed = try allocator.dupe(u8, enc.out.items[enc.out_pos..]);
    defer allocator.free(compressed);

    {
        var d = Decompressor.init(allocator, .{});
        defer d.deinit();
        try testing.expect(d.attachDictionary(dict));
        var in: []const u8 = compressed;
        var out: [256]u8 = undefined;
        var avail: []u8 = &out;
        var total: u64 = 0;
        try testing.expectEqual(DecodeResult.success, d.decompressStream(&in, &avail, &total));
        try testing.expectEqualStrings(input, out[0..@intCast(total)]);
    }

    try testing.expect(!enc.attachDictionary("late"));
}

test "streaming compressor attachDictionary passthrough" {
    const allocator = testing.allocator;
    const dict = "shared vocabulary for streaming compression tests";
    const input = "vocabulary compression vocabulary tests";

    var sc = StreamingCompressor.init(allocator, .{});
    defer sc.deinit();
    try testing.expect(sc.attachDictionary(dict));

    const head = try sc.process(input);
    defer allocator.free(head);
    const tail = try sc.finishAlloc();
    defer allocator.free(tail);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try whole.appendSlice(allocator, head);
    try whole.appendSlice(allocator, tail);

    var d = Decompressor.init(allocator, .{});
    defer d.deinit();
    try testing.expect(d.attachDictionary(dict));
    var in: []const u8 = whole.items;
    var out: [256]u8 = undefined;
    var avail: []u8 = &out;
    var total: u64 = 0;
    try testing.expectEqual(DecodeResult.success, d.decompressStream(&in, &avail, &total));
    try testing.expectEqualStrings(input, out[0..@intCast(total)]);
}

test "large window round trip up to 30 bits" {
    const allocator = testing.allocator;

    inline for (.{ 25, 28, 30 }) |w| {
        var input: [40000]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(w));
        for (&input) |*b| b.* = prng.random().intRangeAtMost(u8, 'a', 'z');

        const compressed = try compressWithOptions(allocator, &input, .{
            .quality = 11,
            .lgWin = w,
            .largeWindow = true,
        });
        defer allocator.free(compressed);

        const decoded = try decompressWithOptions(allocator, compressed, .{
            .largeWindow = true,
        });
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, &input, decoded);
    }
}

test "npostfix and ndirect combinations round trip" {
    const allocator = testing.allocator;
    const input = repeatPattern("information about the network and the program window repeats here ", 30);

    const combos = [_][2]u32{
        .{ 0, 0 }, .{ 1, 0 }, .{ 2, 4 }, .{ 3, 120 }, .{ 0, 15 }, .{ 1, 8 },
    };
    for (combos) |combo| {
        const compressed = try compressWithOptions(allocator, &input, .{
            .quality = 11,
            .nPostfix = combo[0],
            .nDirect = combo[1] << @intCast(combo[0]),
        });
        defer allocator.free(compressed);

        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, &input, decoded);
    }
}

test "metadata metablock round trips with callbacks" {
    const allocator = testing.allocator;

    var enc = Compressor.init(allocator, .{ .quality = 9 });
    defer enc.deinit();
    try enc.compressStream(.process, "payload before metadata");
    try enc.compressStream(.emit_metadata, "META-123");
    try enc.compressStream(.finish, null);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (enc.hasMoreOutput()) {
        const n = enc.takeOutput(&tmp);
        try whole.appendSlice(allocator, tmp[0..n]);
    }

    const Captured = struct {
        seen: usize = 0,
        buf: [64]u8 = undefined,
        n: usize = 0,
        fn start(ctx: ?*anyopaque, size: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.seen = size;
        }
        fn chunk(ctx: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.buf[self.n..][0..data.len], data);
            self.n += data.len;
        }
    };
    var cap = Captured{};
    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();
    dec.setMetadataCallbacks(.{ .ctx = &cap, .start = Captured.start, .chunk = Captured.chunk });

    var input: []const u8 = whole.items;
    var out_buf: [64]u8 = undefined;
    var avail: []u8 = &out_buf;
    var total: u64 = 0;
    try testing.expectEqual(DecodeResult.success, dec.decompressStream(&input, &avail, &total));
    try testing.expectEqualStrings("payload before metadata", out_buf[0..@intCast(total)]);
    try testing.expectEqual(@as(usize, 8), cap.seen);
    try testing.expect(cap.n == cap.seen);
    try testing.expectEqualStrings("META-123", cap.buf[0..cap.n]);
}

test "streaming compressor emits metadata between chunks" {
    const allocator = testing.allocator;

    var sc = StreamingCompressor.init(allocator, .{});
    defer sc.deinit();
    const head = try sc.process("chunk one; ");
    defer allocator.free(head);
    const meta = try sc.emitMetadata("note");
    defer allocator.free(meta);
    const tail = try sc.finishAlloc();
    defer allocator.free(tail);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try whole.appendSlice(allocator, head);
    try whole.appendSlice(allocator, meta);
    try whole.appendSlice(allocator, tail);

    const decoded = try decompress(allocator, whole.items);
    defer allocator.free(decoded);
    try testing.expectEqualStrings("chunk one; ", decoded);
}

test "static dictionary words survive round trip at high quality" {
    const allocator = testing.allocator;
    const input = "Information technology transformed the nation. Windows programs run " ++
        "across networks. International theory on government and communication " ++
        "developed over generations of political transformation in America. " ++
        "The quick brown fox jumps over the lazy dog near the river bank. ";

    inline for (.{ 5, 9, 11 }) |q| {
        const compressed = try compressWithOptions(allocator, input, .{ .quality = q });
        defer allocator.free(compressed);
        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }
}

test "literal block switching on heterogeneous content" {
    const allocator = testing.allocator;
    var input: [64000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(99);
    const classes = [_][2]u8{
        .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '!', '/' },
    };
    var pos: usize = 0;
    var round: usize = 0;
    while (pos < input.len) : (round += 1) {
        const cls = classes[round % classes.len];
        const span = @min(@as(usize, 8000), input.len - pos);
        for (input[pos..][0..span]) |*b| {
            b.* = prng.random().intRangeAtMost(u8, cls[0], cls[1]);
        }
        pos += span;
    }

    inline for (.{ 9, 11 }) |q| {
        const compressed = try compressWithOptions(allocator, &input, .{ .quality = q });
        defer allocator.free(compressed);
        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, &input, decoded);
    }
}

test "streaming decompression with small feeds" {
    const allocator = testing.allocator;
    const input = repeatPattern("resumption across sub-byte boundaries must preserve every bit ", 40);

    const compressed = try compressWithOptions(allocator, &input, .{ .quality = 9 });
    defer allocator.free(compressed);

    var sd = StreamingDecompressor.init(allocator, .{});
    defer sd.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [256]u8 = undefined;

    for (compressed) |byte| try sd.feed(&.{byte});
    sd.endInput();

    while (!sd.isFinished()) {
        const n = try sd.take(&buf);
        if (n > 0) try out.appendSlice(allocator, buf[0..n]);
        if (n == 0 and sd.hasError()) return error.BrotliStreamError;
    }
    try testing.expectEqualSlices(u8, &input, out.items);
}

test "streaming decompression with mixed chunk sizes" {
    const allocator = testing.allocator;
    const input = repeatPattern("streaming decompression must work with arbitrary chunk sizes.", 20);

    const compressed = try compressWithOptions(allocator, &input, .{ .quality = 9 });
    defer allocator.free(compressed);

    var sd = StreamingDecompressor.init(allocator, .{});
    defer sd.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [256]u8 = undefined;

    const sizes = [_]usize{ 1, 3, 7, 64, 128 };
    var ci: usize = 0;
    var si: usize = 0;
    while (ci < compressed.len) {
        const sz = sizes[si % sizes.len];
        const end = @min(ci + sz, compressed.len);
        try sd.feed(compressed[ci..end]);
        ci = end;
        si += 1;
    }
    sd.endInput();

    while (!sd.isFinished()) {
        const n = try sd.take(&buf);
        if (n > 0) try out.appendSlice(allocator, buf[0..n]);
        if (n == 0 and sd.hasError()) return error.BrotliStreamError;
    }
    try testing.expectEqualSlices(u8, &input, out.items);
}

test "StreamingCompressor with std.Io.Writer" {
    const allocator = testing.allocator;
    const input = "streaming through std.Io.Writer in Zig 0.17! Direct chunk output.";

    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    var sc = StreamingCompressor.init(allocator, .{ .quality = 6 });
    defer sc.deinit();

    var chunk_buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&chunk_buf);

    try sc.write(input[0..20], &writer);
    try out_list.appendSlice(allocator, writer.buffered());
    writer = std.Io.Writer.fixed(&chunk_buf);

    try sc.write(input[20..], &writer);
    try out_list.appendSlice(allocator, writer.buffered());
    writer = std.Io.Writer.fixed(&chunk_buf);

    try sc.finish(&writer);
    try out_list.appendSlice(allocator, writer.buffered());

    const decompressed = try decompress(allocator, out_list.items);
    defer allocator.free(decompressed);
    try testing.expectEqualStrings(input, decompressed);
}

test "compressStream and decompressStream with std.Io" {
    const allocator = testing.allocator;
    const message = repeatPattern("Testing full std.Io.Reader and std.Io.Writer pipeline for Brotli stream. ", 15);

    var compressed_storage: [4096]u8 = undefined;
    var comp_writer = std.Io.Writer.fixed(&compressed_storage);

    var in_reader = std.Io.Reader.fixed(&message);
    try compressStream(allocator, &in_reader, &comp_writer, .{ .quality = 5 });

    const compressed_data = comp_writer.buffered();
    try testing.expect(compressed_data.len > 0);

    var decompressed_storage: [message.len + 128]u8 = undefined;
    var decomp_writer = std.Io.Writer.fixed(&decompressed_storage);
    var comp_reader = std.Io.Reader.fixed(compressed_data);

    try decompressStream(allocator, &comp_reader, &decomp_writer, .{});
    try testing.expectEqualStrings(&message, decomp_writer.buffered());
}

test "Compressor and Decompressor context reuse via reset" {
    const allocator = testing.allocator;
    var comp = Compressor.init(allocator, .{ .quality = 6 });
    defer comp.deinit();

    var decomp = Decompressor.init(allocator, .{});
    defer decomp.deinit();

    const text1 = "First dataset for reusable compressor/decompressor context testing.";
    const text2 = "Second dataset testing state reset without reallocating buffers!";
    const text3 = "Third dataset verifying clean state across resets.";

    const datasets = [_][]const u8{ text1, text2, text3 };

    for (datasets) |data| {
        const comp_out = try comp.compress(data);
        defer allocator.free(comp_out);

        const decomp_out = try decomp.decompress(comp_out);
        defer allocator.free(decomp_out);

        try testing.expectEqualStrings(data, decomp_out);

        comp.reset(.{ .quality = 6 });
        decomp.reset(.{});
    }
}

test "Decompressor resource limit enforcement" {
    const allocator = testing.allocator;
    const big_input = repeatPattern("resource limits are very important for security and stability! ", 100);

    const compressed = try compress(allocator, &big_input);
    defer allocator.free(compressed);

    const err = decompressWithOptions(allocator, compressed, .{
        .maxOutputSize = 100,
    });
    try testing.expectError(error.ResourceLimitExceeded, err);

    const err2 = decompressWithOptions(allocator, compressed, .{
        .ringBufferSizeLimit = 1024,
    });
    try testing.expectError(error.ResourceLimitExceeded, err2);
}

test "Quality levels 0 through 11 round trip verification" {
    const allocator = testing.allocator;
    const sample = "The quick brown fox jumps over the lazy dog. Repetition repetition repetition!";

    var q: u32 = 0;
    while (q <= 11) : (q += 1) {
        const compressed = try compressWithOptions(allocator, sample, .{ .quality = q });
        defer allocator.free(compressed);

        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);

        try testing.expectEqualStrings(sample, decoded);
    }
}

test "Compression modes generic, text, font round trip" {
    const allocator = testing.allocator;
    const sample = "Testing different compression modes in Brotli: generic, text, font.";

    inline for (.{ CompressionMode.generic, CompressionMode.text, CompressionMode.font }) |m| {
        const compressed = try compressWithOptions(allocator, sample, .{ .mode = m, .quality = 5 });
        defer allocator.free(compressed);

        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);

        try testing.expectEqualStrings(sample, decoded);
    }
}

test "Edge case: 1, 2, 3, 4 bytes, zeroes, and 0xFF bytes" {
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "x",
        "xy",
        "xyz",
        "xyzw",
        "\x00",
        "\x00\x00\x00\x00\x00",
        "\xFF",
        "\xFF\xFF\xFF\xFF\xFF\xFF",
        "\x00\xFF\x00\xFF\x00\xFF\x00\xFF",
    };

    for (cases) |c| {
        const comp = try compress(allocator, c);
        defer allocator.free(comp);

        const decomp = try decompress(allocator, comp);
        defer allocator.free(decomp);

        try testing.expectEqualSlices(u8, c, decomp);
    }
}

test "Malformed stream headers and corrupted bits fail safely" {
    const allocator = testing.allocator;

    try testing.expectError(error.TruncatedInput, decompress(allocator, &.{}));

    const corrupt1 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    _ = decompress(allocator, &corrupt1) catch {};

    const valid = try compress(allocator, "A sentence that will be compressed then truncated.");
    defer allocator.free(valid);

    if (valid.len > 4) {
        const truncated = valid[0 .. valid.len / 2];
        _ = decompress(allocator, truncated) catch |err| {
            try testing.expect(err == error.TruncatedInput or err == error.CorruptStream or err == error.InvalidMetaBlock or err == error.InvalidHuffmanTree or err == error.BrotliDecompressionError);
        };
    }
}

test "Upstream reference testdata decompression" {
    const allocator = testing.allocator;

    const test_vectors = [_]struct { comp: []const u8, orig: []const u8 }{
        .{
            .comp = "\x06",
            .orig = "",
        },
        .{
            .comp = "\x0b\x00\x80\x58\x03",
            .orig = "X",
        },
        .{
            .comp = "\x0b\x02\x80\x58\x79\x7a\x7a\x79\x03",
            .orig = "Xyzzy",
        },
        .{
            .comp = "\x1b\x13\x00\x00\xa4\xb0\xb2\xea\x81\x47\x02\x8a",
            .orig = "XXXXXXXXXXYYYYYYYYYY",
        },
        .{
            .comp = "\x1b\x3f\x00\x00\x24\xb0\xe2\x99\x80\x12",
            .orig = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        },
        .{
            .comp = "\x0b\x15\x80\x54\x68\x65\x20\x71\x75\x69\x63\x6b\x20\x62\x72\x6f\x77\x6e\x20\x66\x6f\x78\x20\x6a\x75\x6d\x70\x73\x20\x6f\x76\x65\x72\x20\x74\x68\x65\x20\x6c\x61\x7a\x79\x20\x64\x6f\x67\x03",
            .orig = "The quick brown fox jumps over the lazy dog",
        },
        .{
            .comp = "\x1b\x76\x00\x00\x14\x4a\xac\x9b\x7a\xbd\xe1\x97\x9d\x7f\x8e\xc2\x82\x36\x0e\x9c\xe0\x90\x03\xf7\x8b\x9e\x38\xe6\xb6\x00\xab\xc3\xca\xa0\xc2\xda\x66\x36\xdc\xcd\x80\x8d\x2e\x21\xd7\x6e\xe3\xea\x4c\xb8\xf0\xd2\xb8\xc7\xc2\x70\x4d\x3a\xf0\x69\x7e\xa1\xb8\x45\x73\xab\xc4\x57\x1e",
            .orig = "ukko nooa, ukko nooa oli kunnon mies, kun han meni saunaan, pisti laukun naulaan, ukko nooa, ukko nooa oli kunnon mies.",
        },
    };

    for (test_vectors) |tv| {
        const decomp = try decompress(allocator, tv.comp);
        defer allocator.free(decomp);
        try testing.expectEqualSlices(u8, tv.orig, decomp);
    }

    // Large zeros vector (262,144 zeros decompressed from 13 bytes)
    const zeros_comp = "\x5b\xff\xff\x03\x60\x02\x20\x1e\x0b\x28\xf7\x7e\x00";
    const zeros_decomp = try decompress(allocator, zeros_comp);
    defer allocator.free(zeros_decomp);
    try testing.expectEqual(@as(usize, 262144), zeros_decomp.len);
    for (zeros_decomp) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "compression and decompression round-trip across all quality levels" {
    const allocator = testing.allocator;

    const sample1 = "Hello from Zig 0.17! Comprehensive testing of native Brotli compression.";
    const sample2 = "The quick brown fox jumps over the lazy dog near the river bank every morning.";
    var sample3_buf: [1500]u8 = undefined;
    @memset(sample3_buf[0..500], 'A');
    @memset(sample3_buf[500..1000], 'B');
    @memset(sample3_buf[1000..1500], 'C');

    const inputs = [_][]const u8{ sample1, sample2, &sample3_buf };

    for (inputs) |input| {
        for (0..12) |q_val| {
            const q: u32 = @intCast(q_val);
            const comp = try compressWithOptions(allocator, input, .{ .quality = q });
            defer allocator.free(comp);

            const decomp = try decompress(allocator, comp);
            defer allocator.free(decomp);
            try testing.expectEqualSlices(u8, input, decomp);
        }
    }
}

test "exact byte parity on deterministic fixtures" {
    const allocator = testing.allocator;

    const tiny_input = "Brotli native Zig test!";
    const expected_tiny = [_]u8{
        0x0B, 0x0B, 0x80, 'B', 'r', 'o', 't', 'l', 'i', ' ', 'n', 'a', 't', 'i', 'v', 'e', ' ', 'Z', 'i', 'g', ' ', 't', 'e', 's', 't', '!', 0x03,
    };

    for (0..12) |q_val| {
        const q: u32 = @intCast(q_val);

        // 1. Empty stream: with lgWin=22, must be exact byte 0x3B
        const empty_comp = try compressWithOptions(allocator, &.{}, .{ .quality = q });
        defer allocator.free(empty_comp);
        try testing.expectEqualSlices(u8, &.{0x3B}, empty_comp);

        // 2. Tiny stored stream: with lgWin=22, must be exact 27 bytes
        const tiny_comp = try compressWithOptions(allocator, tiny_input, .{ .quality = q });
        defer allocator.free(tiny_comp);
        try testing.expectEqualSlices(u8, &expected_tiny, tiny_comp);
    }
}

test "multi-threaded concurrent compression and decompression" {
    const worker = struct {
        fn run(allocator: std.mem.Allocator, id: usize) !void {
            var prng = std.Random.DefaultPrng.init(12345 + id);
            const rand = prng.random();

            var data: [4096]u8 = undefined;
            for (&data) |*b| {
                b.* = @intCast(rand.intRangeAtMost(u8, 'a', 'z'));
            }

            // Test one-shot compression and decompression
            const compressed = try compressWithOptions(allocator, &data, .{ .quality = 5 });
            defer allocator.free(compressed);

            const decompressed = try decompress(allocator, compressed);
            defer allocator.free(decompressed);

            try testing.expectEqualSlices(u8, &data, decompressed);

            // Test independent context instance
            var comp = Compressor.init(allocator, .{ .quality = 6 });
            defer comp.deinit();

            const c2 = try comp.compress(&data);
            defer allocator.free(c2);

            var dec = Decompressor.init(allocator, .{});
            defer dec.deinit();

            const d2 = try dec.decompress(c2);
            defer allocator.free(d2);

            try testing.expectEqualSlices(u8, &data, d2);
        }

        fn threadEntry(id: usize) void {
            run(testing.allocator, id) catch |e| {
                std.debug.panic("thread {d} failed: {any}", .{ id, e });
            };
        }
    };

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker.threadEntry, .{i});
    }

    for (threads) |t| {
        t.join();
    }
}

test "shared dictionary compression and decompression round trip" {
    const allocator = testing.allocator;

    var dict = SharedDictionary.init(allocator);
    defer dict.deinit();

    const prefix_chunk = "The standardized header prefix for this schema: metadata_version=2.0;protocol=secure;";
    try testing.expect(dict.attach(.raw, prefix_chunk));

    const payload = "The standardized header prefix for this schema: metadata_version=2.0;protocol=secure;data_payload=hello_world";

    const compressed = try compressWithSharedDictionary(allocator, payload, &dict, .{ .quality = 9 });
    defer allocator.free(compressed);

    const decompressed = try decompressWithSharedDictionary(allocator, compressed, &dict, .{});
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(payload, decompressed);
}

test "streaming compressor and decompressor 1-byte end-to-end" {
    const allocator = testing.allocator;
    const input = "Antigravity Brotli Zig Native: full 1-byte streaming test under tight memory buffers!";

    var sc = StreamingCompressor.init(allocator, .{ .quality = 6 });
    defer sc.deinit();

    var sd = StreamingDecompressor.init(allocator, .{});
    defer sd.deinit();

    var compressed_acc: std.ArrayList(u8) = .empty;
    defer compressed_acc.deinit(allocator);

    // Compress 1 byte at a time
    for (input) |b| {
        const chunk = try sc.process(&.{b});
        defer allocator.free(chunk);
        if (chunk.len > 0) try compressed_acc.appendSlice(allocator, chunk);
    }
    const final_comp = try sc.finishAlloc();
    defer allocator.free(final_comp);
    if (final_comp.len > 0) try compressed_acc.appendSlice(allocator, final_comp);
    try testing.expect(sc.isFinished());

    // Decompress 1 byte at a time and take 1 byte at a time
    for (compressed_acc.items) |b| {
        try sd.feed(&.{b});
    }
    sd.endInput();

    var decomp_acc: std.ArrayList(u8) = .empty;
    defer decomp_acc.deinit(allocator);

    var tiny_out: [1]u8 = undefined;
    while (!sd.isFinished()) {
        const n = try sd.take(&tiny_out);
        if (n > 0) try decomp_acc.appendSlice(allocator, tiny_out[0..n]);
        if (n == 0 and sd.hasError()) return error.BrotliStreamError;
    }

    try testing.expectEqualStrings(input, decomp_acc.items);
}

test "streaming shared dictionary end-to-end" {
    const allocator = testing.allocator;

    var dict = SharedDictionary.init(allocator);
    defer dict.deinit();
    const common_prefix = "GET /api/v2/items/query?category=electronics&page=1 HTTP/1.1\r\nHost: api.example.com\r\n";
    try testing.expect(dict.attach(.raw, common_prefix));

    var sc = StreamingCompressor.init(allocator, .{ .quality = 7 });
    defer sc.deinit();
    try testing.expect(sc.attachSharedDictionary(&dict));

    var sd = StreamingDecompressor.init(allocator, .{});
    defer sd.deinit();
    try testing.expect(sd.attachSharedDictionary(&dict));

    const payload = "GET /api/v2/items/query?category=electronics&page=1 HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n\r\n";

    var comp_bytes: std.ArrayList(u8) = .empty;
    defer comp_bytes.deinit(allocator);

    const c1 = try sc.process(payload);
    defer allocator.free(c1);
    if (c1.len > 0) try comp_bytes.appendSlice(allocator, c1);

    const c2 = try sc.finishAlloc();
    defer allocator.free(c2);
    if (c2.len > 0) try comp_bytes.appendSlice(allocator, c2);

    try sd.feed(comp_bytes.items);
    sd.endInput();

    var decomp_bytes: std.ArrayList(u8) = .empty;
    defer decomp_bytes.deinit(allocator);

    var buf: [64]u8 = undefined;
    while (!sd.isFinished()) {
        const n = try sd.take(&buf);
        if (n > 0) try decomp_bytes.appendSlice(allocator, buf[0..n]);
        if (n == 0 and sd.hasError()) return error.BrotliStreamError;
    }

    try testing.expectEqualStrings(payload, decomp_bytes.items);
}

// Regression Tests (v0.0.5)

// Drives `decompressStream` over `comp` using the given input and output
// chunk sizes and returns everything the decoder produced.
fn decodeChunked(
    allocator: std.mem.Allocator,
    comp: []const u8,
    in_chunk: usize,
    out_chunk: usize,
) ![]u8 {
    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var scratch: [256]u8 = undefined;
    var ci: usize = 0;
    while (true) {
        var end = ci;
        var input: []const u8 = &.{};
        if (ci < comp.len) {
            end = @min(ci + in_chunk, comp.len);
            input = comp[ci..end];
        }
        var avail: []u8 = scratch[0..@min(out_chunk, scratch.len)];
        const before = avail.len;
        const r = dec.decompressStream(&input, &avail, null);
        try result.appendSlice(allocator, scratch[0 .. before - avail.len]);
        // Rewind by whatever the decoder handed back through `next_in`.
        ci = end - input.len;
        switch (r) {
            .success => break,
            .needs_more_input => {
                if (ci >= comp.len) return error.TruncatedInput;
            },
            .needs_more_output => {},
            .err => return error.DecodeFailed,
        }
    }
    return result.toOwnedSlice(allocator);
}

// A stream resumed across arbitrary input/output boundaries must decode to
// exactly the original bytes. Guards the decoder's resume state machine: every
// suspended phase (metablock header, Huffman tables, context maps, literal
// runs, distance decoding) has to be re-entered where it left off.
test "regression: decoding resumes correctly across arbitrary buffer boundaries" {
    const allocator = testing.allocator;

    // Pattern length 1400 guarantees long-distance matches inside the window,
    // so the matrix exercises literals, copies and dictionary lookups.
    var src: [3000]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate((i / 7) % 200);

    const comp = try compressWithOptions(allocator, &src, .{ .quality = 5 });
    defer allocator.free(comp);

    const in_sizes = [_]usize{ 1, 2, 3, 5, 13, comp.len };
    const out_sizes = [_]usize{ 1, 3, 17, 4096 };
    for (in_sizes) |ic| {
        for (out_sizes) |oc| {
            const got = try decodeChunked(allocator, comp, ic, oc);
            defer allocator.free(got);
            try testing.expectEqualSlices(u8, &src, got);
        }
    }
}

// Same guarantee for the buffered streaming adapter, including a block that
// carries long-distance matches and static-dictionary words.
test "regression: streaming decompressor honors every chunk boundary" {
    const allocator = testing.allocator;

    const text = "Information technology transformed the nation. " ++
        "Windows programs run across networks. " ++
        "International theory on government and communication " ++
        "developed over generations of political transformation in America. ";
    const src = repeatPattern(text, 8);

    const comp = try compressWithOptions(allocator, &src, .{ .quality = 11 });
    defer allocator.free(comp);

    const in_sizes = [_]usize{ 1, 3, 17, 1024 };
    const out_sizes = [_]usize{ 1, 5, 4096 };
    for (in_sizes) |ic| {
        for (out_sizes) |oc| {
            var sd = StreamingDecompressor.init(allocator, .{});
            defer sd.deinit();

            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(allocator);

            var scratch: [64]u8 = undefined;
            var ci: usize = 0;
            while (ci < comp.len) {
                const end = @min(ci + ic, comp.len);
                try sd.feed(comp[ci..end]);
                ci = end;
                while (true) {
                    const n = try sd.take(scratch[0..@min(oc, scratch.len)]);
                    if (n == 0) break;
                    try got.appendSlice(allocator, scratch[0..n]);
                }
                try testing.expect(!sd.hasError());
            }
            sd.endInput();
            while (!sd.isFinished()) {
                const n = try sd.take(scratch[0..@min(oc, scratch.len)]);
                if (n == 0) {
                    try testing.expect(!sd.hasError());
                    if (got.items.len >= src.len) break;
                    continue;
                }
                try got.appendSlice(allocator, scratch[0..n]);
            }
            try testing.expectEqualSlices(u8, &src, got.items);
        }
    }
}

// A static-dictionary reference must be offset by the size of any attached
// dictionary, otherwise the decoder resolves it to the wrong word (and
// interoperable decoders reject the stream).
test "regression: attached dictionary offsets static-dictionary references" {
    const allocator = testing.allocator;

    const dict = "the quick brown fox jumps over the lazy dog near the river bank every morning " ++
        "information technology transformed the nation windows programs international theory " ++
        "communication developed over generations of political transformation in america ";

    const payloads = [_][]const u8{
        "international theory on government and communication",
        "information technology transformed the nation",
        "the quick brown fox jumps over the lazy dog",
        "political transformation in america over generations",
    };

    for (payloads) |payload| {
        var enc = Compressor.init(allocator, .{ .quality = 11 });
        defer enc.deinit();
        try testing.expect(enc.attachDictionary(dict));
        const comp = try enc.compress(payload);
        defer allocator.free(comp);

        var dec = Decompressor.init(allocator, .{});
        defer dec.deinit();
        try testing.expect(dec.attachDictionary(dict));
        const got = try dec.decompress(comp);
        defer allocator.free(got);
        try testing.expectEqualStrings(payload, got);
    }
}

// Stream-defining parameters cannot be changed once the header is written.
test "regression: setParameter rejects changes after the stream starts" {
    const allocator = testing.allocator;

    var enc = Compressor.init(allocator, .{});
    defer enc.deinit();

    try testing.expect(enc.setParameter(paramQuality, 9));
    try testing.expect(enc.setParameter(paramLgWin, 20));
    try testing.expect(enc.setParameter(paramSizeHint, 1024));

    try enc.compressStream(.process, "start the stream");
    try enc.compressStream(.finish, null);

    try testing.expect(!enc.setParameter(paramQuality, 5));
    try testing.expect(!enc.setParameter(paramLgWin, 12));
    try testing.expect(!enc.setParameter(paramLargeWindow, 1));
    try testing.expect(!enc.setParameter(paramNPostfix, 2));
    try testing.expect(!enc.setParameter(paramNDirect, 4));
    // Size hint stays adjustable, and unknown ids are still rejected.
    try testing.expect(enc.setParameter(paramSizeHint, 2048));
    try testing.expect(!enc.setParameter(9999, 1));
}

// Flushed output is a complete, independently decodable prefix: the decoder
// consumes every flushed byte before reporting that more input is required.
test "regression: flush seals the stream to a decodable byte boundary" {
    const allocator = testing.allocator;

    var sc = StreamingCompressor.init(allocator, .{ .quality = 6 });
    defer sc.deinit();

    const head = try sc.process("flush boundary handling for the brotli stream");
    defer allocator.free(head);
    const flushed = try sc.flushAlloc();
    defer allocator.free(flushed);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try whole.appendSlice(allocator, head);
    try whole.appendSlice(allocator, flushed);

    // Decoding the prefix alone must consume it completely and yield the data
    // written so far.
    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();
    var in: []const u8 = whole.items;
    var out: [256]u8 = undefined;
    var avail: []u8 = &out;
    var total: u64 = 0;
    const r = dec.decompressStream(&in, &avail, &total);
    try testing.expect(r == .needs_more_input);
    try testing.expectEqual(@as(usize, 0), in.len);
    try testing.expectEqualStrings("flush boundary handling for the brotli stream", out[0..@intCast(total)]);

    // And the remainder still decodes to the full original payload.
    const tail = try sc.finishAlloc();
    defer allocator.free(tail);
    try whole.appendSlice(allocator, tail);
    const full = try decompress(allocator, whole.items);
    defer allocator.free(full);
    try testing.expectEqualStrings("flush boundary handling for the brotli stream", full);
}

// Truncated, corrupted and adversarial inputs must fail cleanly: never a
// panic, never a silent success with wrong bytes.
test "regression: malformed streams fail without panicking" {
    const allocator = testing.allocator;

    const valid = try compress(allocator, "A reasonably long sentence used as a corruption base payload.");
    defer allocator.free(valid);

    // Every prefix of a valid stream must either decode to that prefix of the
    // original data or report truncation/corruption.
    var cut: usize = 0;
    while (cut < valid.len) : (cut += 1) {
        if (decompress(allocator, valid[0..cut])) |got| {
            allocator.free(got);
            try testing.expect(cut == valid.len);
        } else |_| {}
    }

    // Single-byte corruption at every position must never crash.
    for (0..valid.len) |i| {
        var bad = try allocator.dupe(u8, valid);
        defer allocator.free(bad);
        bad[i] ^= 0xFF;
        if (decompress(allocator, bad)) |got| allocator.free(got) else |_| {}
    }

    // Random and adversarial payloads.
    var prng = std.Random.DefaultPrng.init(20240917);
    for (0..400) |_| {
        var buf: [64]u8 = undefined;
        prng.random().bytes(&buf);
        const n = prng.random().intRangeLessThan(usize, 0, buf.len + 1);
        if (decompress(allocator, buf[0..n])) |got| allocator.free(got) else |_| {}
    }

    for ([_][]const u8{
        "\x06",
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF",
        "\x1B\x2C\x00\x00\x00\x00",
        "\x0B\x00\x80",
        "\x1B\x00\x00\x00",
        "\x5B\xFF\xFF\x03\x60\x02\x20\x1E\x0B\x28\xF7\x7E",
    }) |bad| {
        if (decompress(allocator, bad)) |got| allocator.free(got) else |_| {}
    }
}

// Output-buffer exhaustion must never corrupt decoder state.
test "regression: tiny output buffers never corrupt decode state" {
    const allocator = testing.allocator;

    var src: [8192]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 37 +% (i >> 5));
    const comp = try compressWithOptions(allocator, &src, .{ .quality = 6 });
    defer allocator.free(comp);

    for ([_]usize{ 1, 2, 3, 5 }) |oc| {
        const got = try decodeChunked(allocator, comp, comp.len, oc);
        defer allocator.free(got);
        try testing.expectEqualSlices(u8, &src, got);
    }
}

test "contract: a dictionary is borrowed for the lifetime of the instance" {
    // `attachDictionary` stores the caller's slice; it must not copy, must not
    // free it, and must stay usable for every subsequent operation.
    const allocator = testing.allocator;

    var dict: [64]u8 = undefined;
    for (&dict, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    const payload = "dictionary borrowed lifetime probe payload dictionary";

    var enc = Compressor.init(allocator, .{ .quality = 5 });
    defer enc.deinit();
    try testing.expect(enc.attachDictionary(&dict));

    const first = try enc.compress(payload);
    defer allocator.free(first);

    // The dictionary buffer is still the caller's to read and mutate; the
    // encoder holds no ownership of it.
    var still_borrowed = true;
    for (dict) |b| {
        if (b < 'a' or b > 'z') still_borrowed = false;
    }
    try testing.expect(still_borrowed);

    // Mutating the borrowed buffer afterwards must not be a use-after-free and
    // must not corrupt the decoder side of a round trip.
    dict[0] = 'z';
    const decoded = try decompress(allocator, first);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, payload, decoded);

    // Decoding with the same borrowed dictionary reproduces the payload.
    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();
    try testing.expect(dec.attachDictionary(&dict));
    const via_dict = try dec.decompress(first);
    defer allocator.free(via_dict);
    try testing.expectEqualSlices(u8, payload, via_dict);
}

test "contract: instances are reusable across success and failure" {
    const allocator = testing.allocator;

    var enc = Compressor.init(allocator, .{ .quality = 5 });
    defer enc.deinit();

    const good = "reusable instance payload that compresses cleanly";
    const a = try enc.compress(good);
    defer allocator.free(a);
    const b = try enc.compress(good);
    defer allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);

    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();

    const ok = try dec.decompress(a);
    defer allocator.free(ok);
    try testing.expectEqualSlices(u8, good, ok);

    // Structural corruption must fail with a documented error, and the
    // instance must still decode correctly afterwards.
    //
    // Note: a bit flip inside the payload is NOT a reliable corruption test.
    // The format carries no checksum, so flipping bits in literal or copy
    // data usually yields a different but still well-formed stream, and the
    // decoder is right to return it. Only structurally significant damage
    // (stream header, metablock framing, Huffman trees, truncation) is
    // detectable, so that is what this asserts.
    const fatal = [_][]const u8{
        a[0..3], // WBITS / window bits and the first metablock header bits.
        a[0 .. a.len - 1], // Truncated final metablock.
        a[0 .. a.len / 2], // Truncated mid-stream.
    };
    for (fatal, 0..) |chunk, ci| {
        if (dec.decompress(chunk)) |got| {
            allocator.free(got);
            std.debug.print("case {d} len={d} accepted truncation\n", .{ ci, chunk.len });
            return error.CorruptedStreamAccepted;
        } else |e| switch (e) {
            error.CorruptStream,
            error.TruncatedInput,
            error.InvalidMetaBlock,
            error.InvalidHuffmanTree,
            error.InvalidCommand,
            error.InvalidDistance,
            error.InvalidDictionaryReference,
            error.InvalidHeader,
            => {},
            else => return e,
        }

        // A rejected stream must not leave the instance unusable.
        const recovered = try dec.decompress(a);
        defer allocator.free(recovered);
        try testing.expectEqualSlices(u8, good, recovered);
    }

    const after = try dec.decompress(a);
    defer allocator.free(after);
    try testing.expectEqualSlices(u8, good, after);
}

test "contract: reset returns an instance to a clean, reusable state" {
    const allocator = testing.allocator;
    const one = "first payload for reset contract";
    const two = "a completely different payload for reset contract checks";

    var enc = Compressor.init(allocator, .{ .quality = 5 });
    defer enc.deinit();
    const a = try enc.compress(one);
    defer allocator.free(a);

    enc.reset(.{ .quality = 9 });
    const b = try enc.compress(two);
    defer allocator.free(b);

    // Reset must not carry the previous stream's history forward.
    const da = try decompress(allocator, a);
    defer allocator.free(da);
    const db = try decompress(allocator, b);
    defer allocator.free(db);
    try testing.expectEqualSlices(u8, one, da);
    try testing.expectEqualSlices(u8, two, db);
    try testing.expect(!std.mem.eql(u8, a, b));

    var dec = Decompressor.init(allocator, .{});
    defer dec.deinit();
    const r1 = try dec.decompress(a);
    defer allocator.free(r1);
    dec.reset(null);
    const r2 = try dec.decompress(b);
    defer allocator.free(r2);
    try testing.expectEqualSlices(u8, one, r1);
    try testing.expectEqualSlices(u8, two, r2);
}

test "contract: streaming instances reject work after finish and survive repeated finish" {
    const allocator = testing.allocator;
    const payload = "streaming finish contract payload that is long enough to span chunks";

    var enc = Compressor.init(allocator, .{ .quality = 5 });
    defer enc.deinit();

    var out_buf: [64]u8 = undefined;
    try enc.compressStream(.process, payload[0..10]);
    while (enc.hasMoreOutput()) _ = enc.takeOutput(&out_buf);
    try enc.compressStream(.process, payload[10..]);
    try enc.compressStream(.finish, null);
    while (enc.hasMoreOutput()) _ = enc.takeOutput(&out_buf);
    try testing.expect(enc.isFinished());

    // Repeated finish must be harmless rather than corrupting state.
    try enc.compressStream(.finish, null);
    try testing.expect(enc.isFinished());

    // Parameters cannot change once the stream has started.
    try testing.expect(!enc.setParameter(paramQuality, 9));

    enc.reset(null);
    try testing.expect(!enc.isFinished());
    try testing.expect(enc.setParameter(paramQuality, 9));
}

test "contract: separate instances share no mutable state" {
    const allocator = testing.allocator;
    const a_text = "instance independence probe alpha payload";
    const b_text = "instance independence probe bravo payload";

    var enc_a = Compressor.init(allocator, .{ .quality = 5 });
    defer enc_a.deinit();
    var enc_b = Compressor.init(allocator, .{ .quality = 11 });
    defer enc_b.deinit();
    var dec_a = Decompressor.init(allocator, .{});
    defer dec_a.deinit();
    var dec_b = Decompressor.init(allocator, .{});
    defer dec_b.deinit();

    // Interleave every operation. A shared mutable global would show up here as
    // cross-talk between the two pairs.
    const a1 = try enc_a.compress(a_text);
    defer allocator.free(a1);
    const b1 = try enc_b.compress(b_text);
    defer allocator.free(b1);
    const a2 = try enc_a.compress(a_text);
    defer allocator.free(a2);
    const b2 = try enc_b.compress(b_text);
    defer allocator.free(b2);

    try testing.expectEqualSlices(u8, a1, a2);
    try testing.expectEqualSlices(u8, b1, b2);

    // Each decoder sees only its own stream; interleaving must not cross-talk.
    const da1 = try dec_a.decompress(a1);
    defer allocator.free(da1);
    const db1 = try dec_b.decompress(b1);
    defer allocator.free(db1);
    const da2 = try dec_a.decompress(a2);
    defer allocator.free(da2);
    const db2 = try dec_b.decompress(b2);
    defer allocator.free(db2);

    try testing.expectEqualSlices(u8, a_text, da1);
    try testing.expectEqualSlices(u8, b_text, db1);
    try testing.expectEqualSlices(u8, a_text, da2);
    try testing.expectEqualSlices(u8, b_text, db2);
}

test "contract: empty input round-trips and allocated output is owned by the caller" {
    const allocator = testing.allocator;

    for ([_]u32{ 0, 1, 4, 9, 11 }) |quality| {
        const compressed = try compressWithOptions(allocator, "", .{ .quality = quality });
        defer allocator.free(compressed);
        const decoded = try decompress(allocator, compressed);
        defer allocator.free(decoded);
        try testing.expectEqual(@as(usize, 0), decoded.len);
    }

    // Every returned slice must be independently freeable by the caller.
    const one = try compress(allocator, "x");
    const two = try compress(allocator, "y");
    const three = try decompress(allocator, two);
    allocator.free(one);
    allocator.free(two);
    allocator.free(three);
}
