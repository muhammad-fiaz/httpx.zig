//! Content compression: negotiation + encode/decode for gzip, deflate, zstd, brotli.
//!
//! Negotiation follows RFC 9110 section 12.5.3 (Accept-Encoding):
//! the client sends Accept-Encoding, the server selects one encoding
//! and responds with Content-Encoding. Identity is never compressed.
//!
//! Uses:
//!   * std.compress.flate for gzip + zlib (Zig builtin)
//!   * zstd dependency for zstd
//!   * brotli dependency for br
//!
//! References:
//!   - RFC 9110 Section 12.5.3 — Content-Encoding
//!   - RFC 9110 Section 12.5.1 — Accept-Encoding

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const zstdMod = @import("zstd");
const brotliMod = @import("brotli");
const parseMod = @import("../common/parse.zig");

pub const Error = error{
    UnsupportedEncoding,
    CorruptData,
    OutOfMemory,
    DecompressedTooLarge,
    NotAcceptable,
};

pub const MAX_DECOMPRESSED_SIZE: usize = 64 * 1024 * 1024;

/// Content codings we support, in preference order (most preferred first).
pub const Encoding = enum {
    zstd,
    br,
    gzip,
    deflate,
    identity,

    pub fn token(self: Encoding) []const u8 {
        return switch (self) {
            .zstd => "zstd",
            .br => "br",
            .gzip => "gzip",
            .deflate => "deflate",
            .identity => "identity",
        };
    }

    pub fn fromToken(tok: []const u8) ?Encoding {
        if (std.ascii.eqlIgnoreCase(tok, "zstd")) return .zstd;
        if (std.ascii.eqlIgnoreCase(tok, "br")) return .br;
        if (std.ascii.eqlIgnoreCase(tok, "gzip") or std.ascii.eqlIgnoreCase(tok, "x-gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(tok, "deflate") or std.ascii.eqlIgnoreCase(tok, "x-deflate")) return .deflate;
        if (std.ascii.eqlIgnoreCase(tok, "identity")) return .identity;
        return null;
    }
};

pub const ParsedEncoding = struct {
    encoding: Encoding,
    q: f32 = 1.0,
};

fn parseQuality(text: []const u8) f32 {
    if (text.len == 0) return 0;
    if (text[0] == '0') {
        if (text.len == 1) return 0;
        if (text[1] != '.' or text.len > 5) return 0;
        var numerator: u16 = 0;
        var denominator: f32 = 1;
        for (text[2..]) |digit| {
            if (digit < '0' or digit > '9') return 0;
            numerator = numerator * 10 + (digit - '0');
            denominator *= 10;
        }
        return @as(f32, @floatFromInt(numerator)) / denominator;
    }
    if (text[0] == '1') {
        if (text.len == 1) return 1;
        if (text[1] != '.' or text.len > 5) return 0;
        for (text[2..]) |digit| {
            if (digit != '0') return 0;
        }
        return 1;
    }
    return 0;
}

const encodingCount = @typeInfo(Encoding).@"enum".field_values.len;
const EncodingTag = @typeInfo(Encoding).@"enum".tag_type;

/// The q-value weights of one `Accept-Encoding` header, resolved once.
///
/// Both the weighted-list view (`parseAcceptEncoding`) and the single-choice
/// view (`negotiate`) are derived from this, so the two can never disagree
/// about what a header says. Parsing allocates nothing.
const Weights = struct {
    /// q per coding named explicitly in the header.
    explicit: [encodingCount]?f32,
    /// q from the `*` token, when present.
    wildcard: ?f32 = null,
    fn parse(headerValue: []const u8) Weights {
        var self: Weights = .{ .explicit = @splat(null) };

        var it = parseMod.TokenListIterator.init(headerValue);
        while (it.next()) |part| {
            var paramIt = parseMod.ParamIterator.init(part);
            const firstParam = paramIt.next() orelse continue;
            const tok = firstParam.key;
            var q: f32 = 1.0;

            while (paramIt.next()) |param| {
                if (parseMod.eqlIgnoreCase(param.key, "q")) {
                    q = parseQuality(param.value);
                }
            }

            if (tok.len == 1 and tok[0] == '*') {
                self.wildcard = q;
            } else if (Encoding.fromToken(tok)) |enc| {
                self.explicit[@backingInt(enc)] = q;
            }
            // Unknown tokens are ignored per RFC 9110 section 12.5.3.
        }
        return self;
    }

    /// Effective q for a coding: its own q, else the wildcard's, else zero.
    /// Identity has an implicit quality of 1 unless explicitly refused, or
    /// refused by `*;q=0` when no identity quality was supplied.
    fn quality(self: Weights, enc: Encoding) f32 {
        if (self.explicit[@backingInt(enc)]) |q| return q;
        if (enc == .identity) {
            if (self.wildcard) |q| {
                if (q == 0) return 0;
            }
            return 1;
        }
        if (self.wildcard) |q| return q;
        return 0.0;
    }
};

/// Parses an `Accept-Encoding` header value into weighted entries.
///
/// Entries come back in header order, one per coding, so a coding listed twice
/// appears once. The `*` wildcard expands to every coding it is allowed to
/// cover, excluding `identity` (which is always acceptable and never what a
/// wildcard is asking for) and anything already named explicitly. Unknown
/// tokens are ignored per RFC 9110 section 12.5.3.
///
/// Allocates; the caller owns the result.
pub fn parseAcceptEncoding(allocator: Allocator, headerValue: []const u8) ![]ParsedEncoding {
    const weights = Weights.parse(headerValue);

    var seen: [encodingCount]bool = @splat(false);
    var results = std.ArrayList(ParsedEncoding).empty;
    errdefer results.deinit(allocator);

    var it = parseMod.TokenListIterator.init(headerValue);
    while (it.next()) |part| {
        var paramIt = parseMod.ParamIterator.init(part);
        const firstParam = paramIt.next() orelse continue;
        const tok = firstParam.key;

        if (tok.len == 1 and tok[0] == '*') {
            const q = weights.wildcard orelse continue;
            for (0..encodingCount) |i| {
                const enc: Encoding = @fromBackingInt(@intCast(@as(EncodingTag, @intCast(i))));
                if (enc == .identity or seen[i]) continue;
                // A coding named explicitly elsewhere in the header keeps its own
                // q; the wildcard only covers codings nobody asked for by name.
                if (weights.explicit[i] != null) continue;
                seen[i] = true;
                try results.append(allocator, .{ .encoding = enc, .q = q });
            }
            continue;
        }

        if (Encoding.fromToken(tok)) |enc| {
            if (seen[@backingInt(enc)]) continue;
            seen[@backingInt(enc)] = true;
            try results.append(allocator, .{ .encoding = enc, .q = weights.quality(enc) });
        }
    }
    return results.toOwnedSlice(allocator);
}

/// Picks the best encoding we support from the client's `Accept-Encoding`.
///
/// Returns `.identity` when nothing acceptable remains, which is always a
/// legal response regardless of what the client asked for.
pub fn negotiate(headerValue: []const u8) ?Encoding {
    const weights = Weights.parse(headerValue);

    var best: ?Encoding = null;
    var bestQ: f32 = 0.0;
    inline for (@typeInfo(Encoding).@"enum".field_values) |fvalue| {
        const enc: Encoding = @fromBackingInt(@intCast(fvalue));
        const q = weights.quality(enc);
        if (q > 0 and (best == null or q > bestQ or (q == bestQ and preference(enc) > preference(best.?)))) {
            best = enc;
            bestQ = q;
        }
    }
    return best;
}

fn preference(e: Encoding) u8 {
    return switch (e) {
        .zstd => 4,
        .br => 3,
        .gzip => 2,
        .deflate => 1,
        .identity => 0,
    };
}

// Codecs

/// Quality used for Brotli on the HTTP path. The package default is 11, which is
/// disproportionately slow for the small bodies a server compresses; 5 is the
/// usual interactive trade-off. `brotliMod.maxQuality` remains reachable
/// through `Config`.
pub const defaultBrotliQuality: u32 = 5;

/// Typed compression settings. Every field has a default, so `.{}` is valid.
pub const Config = struct {
    /// zstd compression level: 1 (fastest) through 22 (best), negative for the
    /// fast modes. Clamped by the package to its supported range.
    zstdLevel: i32 = zstdMod.CLEVEL_DEFAULT,
    /// Brotli quality, 0 (fastest) through 11 (best ratio).
    brotliQuality: u32 = defaultBrotliQuality,
    /// Brotli sliding-window size in bits.
    brotliWindowBits: u32 = brotliMod.defaultWindow,
    /// When true, `compressWithConfig` reports `.identity` instead of the
    /// requested coding whenever the codec failed to shrink the payload. HTTP
    /// permits sending an unencoded body whatever the client offered, and
    /// advertising `Content-Encoding` for bytes that grew is a net loss.
    preferSmaller: bool = true,
};

/// Outcome of a compression attempt.
///
/// The `encoding` field is the coding the `bytes` actually carry. It is
/// `.identity` when the payload was passed through unchanged, so a caller can
/// derive `Content-Encoding` from this value and cannot desynchronise the
/// header from the bytes.
pub const Compressed = struct {
    encoding: Encoding,
    bytes: []u8,

    /// True when a content coding was actually applied.
    pub fn isCoded(self: Compressed) bool {
        return self.encoding != .identity;
    }
};

/// Compresses `data`, always applying `encoding`.
///
/// The returned slice carries exactly `encoding`; this function never
/// substitutes another codec, so `encoding.token()` always labels `bytes`
/// correctly. Use `compressWithConfig` when a codec that failed to shrink the
/// payload should fall back to identity instead.
pub fn compress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8 {
    const result = try compressWithConfig(allocator, encoding, data, .{ .preferSmaller = false });
    return result.bytes;
}

/// Compresses `data` with `config`, reporting the coding that was really used.
///
/// With `Config.preferSmaller` the result may be `.identity` even though a
/// real coding was requested and succeeded; `result.encoding` is authoritative.
pub fn compressWithConfig(allocator: Allocator, encoding: Encoding, data: []const u8, config: Config) !Compressed {
    if (encoding == .identity) {
        return .{ .encoding = .identity, .bytes = try allocator.dupe(u8, data) };
    }

    const coded = switch (encoding) {
        .zstd => zstdMod.compressWithLevel(allocator, data, config.zstdLevel) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.CorruptData,
        },
        .br => brotliMod.compressWithOptions(allocator, data, .{
            .quality = @min(config.brotliQuality, brotliMod.maxQuality),
            .lgWin = config.brotliWindowBits,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.CorruptData,
        },
        .gzip, .deflate => try flateCompress(allocator, encoding == .gzip, data),
        .identity => unreachable,
    };

    if (config.preferSmaller and coded.len >= data.len) {
        allocator.free(coded);
        return .{ .encoding = .identity, .bytes = try allocator.dupe(u8, data) };
    }
    return .{ .encoding = encoding, .bytes = coded };
}

/// How a response body should be sent.
pub const ResponseCoding = struct {
    /// The bytes to write to the wire.
    body: []const u8,
    /// The `Content-Encoding` value describing `body`, or null when it is sent
    /// unencoded.
    contentEncoding: ?[]const u8,
    /// True when the body is eligible for this server's content negotiation;
    /// the response should then carry `Vary: Accept-Encoding` even if this
    /// request selected identity.
    varyAcceptEncoding: bool,
};

/// Decides how to encode a response body given the client's `Accept-Encoding`.
///
/// Returns unencoded when the client offered no coding, when the coding that
/// wins negotiation is identity, when the body is empty or carries no body
/// semantics, or when it is larger than `maxInput` — the last bounds the memory
/// one request can hold to roughly input plus compressed copy.
///
/// When `contentEncoding` is non-null the caller owns `body` and must free it
/// with `allocator`; otherwise `body` borrows the input unchanged.
pub fn encodeResponseBody(
    allocator: Allocator,
    body: []const u8,
    acceptEncoding: ?[]const u8,
    config: Config,
    maxInput: usize,
) !ResponseCoding {
    const varies = body.len > 0 and body.len <= maxInput;
    const unencoded: ResponseCoding = .{ .body = body, .contentEncoding = null, .varyAcceptEncoding = varies };
    if (!varies) return unencoded;

    const header = acceptEncoding orelse return unencoded;

    const selected = negotiate(header) orelse return Error.NotAcceptable;
    if (selected == .identity) return unencoded;

    // Apply the coding, then decide whether it was worth it here rather than
    // letting compressWithConfig fall back: the fallback duplicates the body,
    // and unencoded bytes are borrowed, not owned.
    var cfg = config;
    cfg.preferSmaller = false;
    const result = try compressWithConfig(allocator, selected, body, cfg);
    if (config.preferSmaller and result.bytes.len >= body.len) {
        if (Weights.parse(header).quality(.identity) > 0) {
            allocator.free(result.bytes);
            return unencoded;
        }
        // Identity is forbidden, so keep the selected coding even when its
        // framing overhead makes this particular payload larger.
        return .{ .body = result.bytes, .contentEncoding = result.encoding.token(), .varyAcceptEncoding = true };
    }
    return .{ .body = result.bytes, .contentEncoding = result.encoding.token(), .varyAcceptEncoding = true };
}

/// Parses a `Content-Encoding` or `Accept-Encoding` token.
/// Returns `Error.UnsupportedEncoding` for a coding httpx does not implement.
pub fn encodingFromToken(token: []const u8) Error!Encoding {
    return Encoding.fromToken(std.mem.trim(u8, token, " \t")) orelse Error.UnsupportedEncoding;
}

/// The `Accept-Encoding` value advertising every coding this build can decode.
///
/// Derived from `Encoding` in server preference order, so the advertisement
/// cannot drift from the implemented set. Evaluated entirely at comptime: the
/// result is a static string, not a formatted buffer.
pub fn acceptEncodingValue() []const u8 {
    return comptime Encoding.zstd.token() ++
        ", " ++ Encoding.br.token() ++
        ", " ++ Encoding.gzip.token() ++
        ", " ++ Encoding.deflate.token();
}

fn flateCompress(allocator: Allocator, gzipContainer: bool, data: []const u8) ![]u8 {
    const initialCapacity = std.math.add(usize, data.len, 64) catch return Error.OutOfMemory;
    var output = std.Io.Writer.Allocating.initCapacity(allocator, initialCapacity) catch
        return Error.OutOfMemory;
    defer output.deinit();
    const history = allocator.alloc(u8, flate.max_window_len * 2) catch return Error.OutOfMemory;
    defer allocator.free(history);

    var compressor = flate.Compress.init(
        &output.writer,
        history,
        if (gzipContainer) .gzip else .zlib,
        .default,
    ) catch return Error.CorruptData;
    compressor.writer.writeAll(data) catch return Error.CorruptData;
    flate.Compress.finish(&compressor) catch return Error.CorruptData;
    return output.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Decompresses with the given encoding (bounded by MAX_DECOMPRESSED_SIZE).
pub fn decompress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8 {
    return decompressLimited(allocator, encoding, data, MAX_DECOMPRESSED_SIZE);
}

/// Decompresses content while rejecting expansion beyond `maxSize`.
/// This is intended for response bodies and other untrusted compressed input.
pub fn decompressLimited(allocator: Allocator, encoding: Encoding, data: []const u8, maxSize: usize) ![]u8 {
    // Every real content coding emits at least one byte, so an empty body that
    // claims one is a truncated transfer, not a valid empty payload. Reporting
    // success with zero bytes would let a broken response pass as a good one,
    // and would hide a truncated download from size and checksum checks.
    if (encoding != .identity and data.len == 0) return Error.CorruptData;
    return switch (encoding) {
        .identity => if (data.len > maxSize) Error.DecompressedTooLarge else allocator.dupe(u8, data),
        .zstd => {
            const bound = zstdMod.decompressBound(allocator, data) catch return Error.CorruptData;
            if (bound > maxSize) return Error.DecompressedTooLarge;
            return zstdMod.decompress(allocator, data) catch Error.CorruptData;
        },
        .br => brotliDecompressLimited(allocator, data, maxSize),
        .gzip, .deflate => flateDecompressLimited(allocator, encoding == .gzip, data, maxSize),
    };
}

/// Decompresses Brotli under a hard output bound.
///
/// The bound is handed to the brotli decoder as `maxOutputSize` so the limit is
/// enforced by the codec itself rather than detected after the fact: the
/// decoder fails with `error.ResourceLimitExceeded` before it can write past
/// `maxSize`, and grows its own buffer to the exact final length.
fn brotliDecompressLimited(allocator: Allocator, data: []const u8, maxSize: usize) ![]u8 {
    var decoder = brotliMod.Decoder.init(allocator, .{ .maxOutputSize = maxSize });
    defer decoder.deinit();
    return decoder.decompress(data) catch |err| switch (err) {
        error.ResourceLimitExceeded, error.OutputLimitExceeded => Error.DecompressedTooLarge,
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.CorruptData,
    };
}

fn flateDecompressLimited(allocator: Allocator, isGzip: bool, data: []const u8, maxSize: usize) ![]u8 {
    var inReader = std.Io.Reader.fixed(data);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var decomp = flate.Decompress.init(&inReader, if (isGzip) .gzip else .zlib, window);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&buf) catch return Error.CorruptData;
        if (n == 0) break;
        const newLen = std.math.add(usize, out.items.len, n) catch return Error.DecompressedTooLarge;
        if (newLen > maxSize) return Error.DecompressedTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

// Tests

test "accept-encoding parse basic" {
    const a = std.testing.allocator;
    const parsed = try parseAcceptEncoding(a, "gzip, deflate, br");
    defer a.free(parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(Encoding.gzip, parsed[0].encoding);
    try std.testing.expectEqual(@as(f32, 1.0), parsed[0].q);
}

test "accept-encoding parse with q-values" {
    const a = std.testing.allocator;
    const parsed = try parseAcceptEncoding(a, "br;q=0.8, gzip;q=0.5, *;q=0.1");
    defer a.free(parsed);
    try std.testing.expectEqual(@as(f32, 0.8), parsed[0].q);
    try std.testing.expectEqual(@as(f32, 0.5), parsed[1].q);
}

test "negotiate prefers zstd when offered" {
    try std.testing.expectEqual(@as(?Encoding, .zstd), negotiate("gzip, br, zstd"));
    try std.testing.expectEqual(@as(?Encoding, .br), negotiate("gzip, br"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("gzip;q=0.9, identity"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("gzip;q=0.9"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate(""));
}

test "negotiate respects q=0 rejection" {
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("zstd;q=0"));
    try std.testing.expectEqual(@as(?Encoding, null), negotiate("identity;q=0, *;q=0"));
}

test "negotiate rejects malformed and out-of-range quality values" {
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("gzip;q=bogus"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("br;q=1.1"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("zstd;q=-0.1"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("gzip;q=0.1234"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("gzip;q=1e0"));
}

test "negotiate applies wildcard to unspecified codings" {
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("*;q=0.4"));
    try std.testing.expectEqual(@as(?Encoding, null), negotiate("*;q=0, identity;q=0"));
    try std.testing.expectEqual(@as(?Encoding, .identity), negotiate("*;q=0.4, zstd;q=0, br;q=0"));
}

test "roundtrip zstd" {
    const a = std.testing.allocator;
    const original = "hello hello hello hello world!";
    const compressed = try compress(a, .zstd, original);
    defer a.free(compressed);
    const restored = try decompress(a, .zstd, compressed);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "roundtrip brotli" {
    const a = std.testing.allocator;
    const original = "brotli roundtrip test data";
    const compressed = try compress(a, .br, original);
    defer a.free(compressed);
    const restored = try decompress(a, .br, compressed);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "roundtrip gzip and deflate" {
    const a = std.testing.allocator;
    const original = "native flate compression is available";
    inline for (.{ Encoding.gzip, Encoding.deflate }) |encoding| {
        const compressed = try compress(a, encoding, original);
        defer a.free(compressed);
        const restored = try decompress(a, encoding, compressed);
        defer a.free(restored);
        try std.testing.expectEqualStrings(original, restored);
    }
}

test "limited decompression rejects oversized identity and zstd output" {
    const a = std.testing.allocator;
    const original = "bounded decompression output";
    try std.testing.expectError(Error.DecompressedTooLarge, decompressLimited(a, .identity, original, 4));
    const empty = try decompressLimited(a, .identity, "", 0);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const compressed = try compress(a, .zstd, original);
    defer a.free(compressed);
    try std.testing.expectError(Error.DecompressedTooLarge, decompressLimited(a, .zstd, compressed, 4));
    const restored = try decompressLimited(a, .zstd, compressed, original.len);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "limited brotli decompression grows within the configured bound" {
    const a = std.testing.allocator;
    const pat = "brotli bounded output ";
    const original: [pat.len * 512]u8 = comptime blk: {
        var out: [pat.len * 512]u8 = undefined;
        for (0..512) |i| @memcpy(out[i * pat.len ..][0..pat.len], pat);
        break :blk out;
    };
    const compressed = try compress(a, .br, &original);
    defer a.free(compressed);
    try std.testing.expectError(Error.DecompressedTooLarge, decompressLimited(a, .br, compressed, original.len - 1));
    const restored = try decompressLimited(a, .br, compressed, original.len);
    defer a.free(restored);
    try std.testing.expectEqualStrings(&original, restored);
}

// Typed configuration, fallbacks, and edge payloads.

/// Repeats `pattern` `count` times into a comptime array. Zig has no literal
/// repetition operator for slices, and these payloads must exist before any
/// test body runs.
fn repeatPayload(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    var out: [pattern.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(out[i * pattern.len ..][0..pattern.len], pattern);
    return out;
}

test "compressWithConfig reports the coding actually applied" {
    const a = std.testing.allocator;
    const compressible: []const u8 = &repeatPayload("repeating payload that every codec shrinks ", 40);

    inline for (.{ Encoding.zstd, Encoding.br, Encoding.gzip, Encoding.deflate }) |enc| {
        const result = try compressWithConfig(a, enc, compressible, .{});
        defer a.free(result.bytes);
        try std.testing.expectEqual(enc, result.encoding);
        try std.testing.expect(result.isCoded());
        try std.testing.expect(result.bytes.len < compressible.len);

        // The declared coding must be the one the bytes actually carry.
        const back = try decompressLimited(a, enc, result.bytes, compressible.len);
        defer a.free(back);
        try std.testing.expectEqualStrings(compressible, back);
    }
}

test "compressWithConfig falls back to identity when coding does not shrink" {
    const a = std.testing.allocator;
    // Incompressible: no content coding can make this smaller.
    var tiny: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    prng.random().bytes(&tiny);

    const result = try compressWithConfig(a, .zstd, &tiny, .{});
    defer a.free(result.bytes);
    try std.testing.expectEqual(Encoding.identity, result.encoding);
    try std.testing.expect(!result.isCoded());
    try std.testing.expectEqualSlices(u8, &tiny, result.bytes);
}

test "preferSmaller disabled still applies the requested coding" {
    const a = std.testing.allocator;
    const original = "no";
    const result = try compressWithConfig(a, .zstd, original, .{ .preferSmaller = false });
    defer a.free(result.bytes);
    try std.testing.expectEqual(Encoding.zstd, result.encoding);
    const back = try decompressLimited(a, .zstd, result.bytes, original.len);
    defer a.free(back);
    try std.testing.expectEqualStrings(original, back);
}

test "identity coding passes bytes through unchanged" {
    const a = std.testing.allocator;
    const result = try compressWithConfig(a, .identity, "unchanged payload", .{});
    defer a.free(result.bytes);
    try std.testing.expectEqual(Encoding.identity, result.encoding);
    try std.testing.expect(!result.isCoded());
    try std.testing.expectEqualStrings("unchanged payload", result.bytes);
}

test "zstd and brotli are applied at sizes past the old 256KiB downgrade" {
    // Regression: `compress` used to silently emit gzip bytes for a .zstd
    // request above 256 KiB, so a caller labelling the result `zstd` shipped
    // gzip. Both codings must now hold at every size.
    const a = std.testing.allocator;
    const pattern = "the quick brown fox jumps over the lazy dog ";
    const original = try a.alloc(u8, pattern.len * 9000); // ~387 KiB
    defer a.free(original);
    for (original, 0..) |*b, i| b.* = pattern[i % pattern.len];

    inline for (.{ Encoding.zstd, Encoding.br }) |enc| {
        const coded = try compress(a, enc, original);
        defer a.free(coded);
        // A real frame for that coding, not a substituted one.
        if (enc == .zstd) {
            try std.testing.expect(zstdMod.isZstdFrame(coded));
        } else {
            // Brotli has no magic number; round-tripping is the check.
            try std.testing.expect(coded.len > 0);
        }
        const back = try decompressLimited(a, enc, coded, original.len);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, original, back);
    }
}

test "empty body round trips through every coding" {
    const a = std.testing.allocator;
    inline for (.{ Encoding.zstd, Encoding.br, Encoding.gzip, Encoding.deflate, Encoding.identity }) |enc| {
        const coded = try compress(a, enc, "");
        defer a.free(coded);
        const back = try decompressLimited(a, enc, coded, 1024);
        defer a.free(back);
        try std.testing.expectEqualStrings("", back);
    }
}

test "large payload round trips through every coding" {
    const a = std.testing.allocator;
    // 2 MiB of mixed text and high-entropy bytes.
    var original = try a.alloc(u8, 2 * 1024 * 1024);
    defer a.free(original);
    var prng = std.Random.DefaultPrng.init(4242);
    prng.random().bytes(original);
    for (0..original.len / 64) |i| {
        @memset(original[i * 64 ..][0..32], 'a' + @as(u8, @intCast(i % 26)));
    }

    inline for (.{ Encoding.zstd, Encoding.br, Encoding.gzip, Encoding.deflate }) |enc| {
        const coded = try compress(a, enc, original);
        defer a.free(coded);
        const back = try decompressLimited(a, enc, coded, original.len);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, original, back);
    }
}

test "malformed payloads surface CorruptData rather than a panic or empty body" {
    const a = std.testing.allocator;
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x13, 0x37 };

    inline for (.{ Encoding.zstd, Encoding.br, Encoding.gzip, Encoding.deflate }) |enc| {
        // Garbage in: must be a reported error, never a silent success.
        try std.testing.expectError(Error.CorruptData, decompressLimited(a, enc, &garbage, 4096));
        // Empty input is not a valid coded stream either.
        try std.testing.expectError(Error.CorruptData, decompressLimited(a, enc, "", 4096));

        // A valid frame cut in half must not decode.
        const good = try compress(a, enc, "a payload long enough to truncate meaningfully and still decode or fail");
        defer a.free(good);
        if (good.len > 2) {
            try std.testing.expectError(Error.CorruptData, decompressLimited(a, enc, good[0 .. good.len / 2], 4096));
        }
    }
}

test "every advertised coding is decodable" {
    // The client sends `acceptEncodingValue()` verbatim, so every token in it
    // must name a coding this build can both produce and consume.
    const a = std.testing.allocator;
    const payload: []const u8 = &repeatPayload("advertisement must be honest about what the build supports ", 12);

    var it = std.mem.splitScalar(u8, acceptEncodingValue(), ',');
    var count: usize = 0;
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) continue;
        count += 1;

        const enc = try encodingFromToken(token);
        try std.testing.expectEqualStrings(token, enc.token());

        const coded = try compress(a, enc, payload);
        defer a.free(coded);
        const back = try decompressLimited(a, enc, coded, payload.len);
        defer a.free(back);
        try std.testing.expectEqualStrings(payload, back);
    }
    try std.testing.expect(count >= 3);
}

test "accept-encoding value is ordered by server preference" {
    try std.testing.expectEqualStrings("zstd, br, gzip, deflate", acceptEncodingValue());
    try std.testing.expectEqual(@as(?Encoding, .zstd), negotiate(acceptEncodingValue()));
}

test "encodingFromToken rejects codings this build does not implement" {
    try std.testing.expectError(Error.UnsupportedEncoding, encodingFromToken("exi"));
    try std.testing.expectError(Error.UnsupportedEncoding, encodingFromToken("compress"));
    try std.testing.expectError(Error.UnsupportedEncoding, encodingFromToken(""));
    try std.testing.expectEqual(Encoding.br, try encodingFromToken("  BR  "));
    try std.testing.expectEqual(Encoding.gzip, try encodingFromToken("x-gzip"));
}

test "parse-encoding wildcard excludes identity and keeps header order" {
    const a = std.testing.allocator;
    // The wildcard covers only codings nobody named, so `gzip` and `br` keep
    // their own q=0.5 while `zstd` and `deflate` inherit the wildcard's 0.9.
    const parsed = try parseAcceptEncoding(a, "gzip;q=0.5, *;q=0.9, br;q=0.5");
    defer a.free(parsed);

    try std.testing.expectEqual(@as(usize, 4), parsed.len);
    try std.testing.expectEqual(Encoding.gzip, parsed[0].encoding);
    try std.testing.expectEqual(@as(f32, 0.5), parsed[0].q);
    try std.testing.expectEqual(Encoding.zstd, parsed[1].encoding);
    try std.testing.expectEqual(@as(f32, 0.9), parsed[1].q);
    try std.testing.expectEqual(Encoding.deflate, parsed[2].encoding);
    try std.testing.expectEqual(@as(f32, 0.9), parsed[2].q);
    try std.testing.expectEqual(Encoding.br, parsed[3].encoding);
    try std.testing.expectEqual(@as(f32, 0.5), parsed[3].q);

    for (parsed) |entry| {
        try std.testing.expect(entry.encoding != .identity);
    }
}

test "parse-encoding never lists a coding twice" {
    const a = std.testing.allocator;
    const parsed = try parseAcceptEncoding(a, "br, br, br");
    defer a.free(parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqual(Encoding.br, parsed[0].encoding);
}

test "response coding encodes a negotiable body" {
    const a = std.testing.allocator;
    const body: []const u8 = &repeatPayload("negotiable response body that shrinks ", 32);

    const coding = try encodeResponseBody(a, body, "zstd, br", .{}, 1024 * 1024);
    defer a.free(coding.body);
    try std.testing.expectEqualStrings("zstd", coding.contentEncoding.?);
    try std.testing.expect(coding.body.len < body.len);

    const back = try decompressLimited(a, .zstd, coding.body, body.len);
    defer a.free(back);
    try std.testing.expectEqualStrings(body, back);
}

test "response coding is skipped when it is not wanted, allowed, or useful" {
    const a = std.testing.allocator;
    const body: []const u8 = &repeatPayload("a body large enough that every codec can shrink it ", 32);

    // No Accept-Encoding at all.
    const none = try encodeResponseBody(a, body, null, .{}, 1024 * 1024);
    try std.testing.expect(none.contentEncoding == null);
    try std.testing.expectEqual(body.ptr, none.body.ptr);

    // Client refused every coding.
    const refused = try encodeResponseBody(a, body, "identity, zstd;q=0", .{}, 1024 * 1024);
    try std.testing.expect(refused.contentEncoding == null);

    // Empty body, and a body past the configured ceiling.
    const empty = try encodeResponseBody(a, "", "gzip", .{}, 1024 * 1024);
    try std.testing.expect(empty.contentEncoding == null);
    const oversized = try encodeResponseBody(a, body, "gzip", .{}, 8);
    try std.testing.expect(oversized.contentEncoding == null);
    try std.testing.expectEqual(body.ptr, oversized.body.ptr);
    try std.testing.expectError(Error.NotAcceptable, encodeResponseBody(a, body, "identity;q=0, *;q=0", .{}, 1024 * 1024));
}

test "response coding honors identity refusal and preferSmaller configuration" {
    const a = std.testing.allocator;
    const body = "tiny";
    const forced = try encodeResponseBody(a, body, "gzip, identity;q=0", .{}, 1024);
    defer a.free(forced.body);
    try std.testing.expectEqualStrings("gzip", forced.contentEncoding.?);
    try std.testing.expect(forced.body.len >= body.len);

    const configured = try encodeResponseBody(a, body, "gzip", .{ .preferSmaller = false }, 1024);
    defer a.free(configured.body);
    try std.testing.expectEqualStrings("gzip", configured.contentEncoding.?);
}

test "response coding reports identity when the codec does not shrink" {
    const a = std.testing.allocator;
    // A body no coding can shrink must go out unencoded rather than be
    // advertised under a coding that did not help. Eight bytes are too few for
    // any frame header to pay for itself.
    const body = "12345678";
    const coding = try encodeResponseBody(a, body, "zstd", .{}, 1024 * 1024);
    try std.testing.expect(coding.contentEncoding == null);
    try std.testing.expectEqualStrings(body, coding.body);
}

test "response coding honours the configured input ceiling" {
    const a = std.testing.allocator;
    const body: []const u8 = &repeatPayload("document asset body ", 128);
    const coding = try encodeResponseBody(a, body, "br", .{}, body.len);
    defer a.free(coding.body);
    try std.testing.expectEqualStrings("br", coding.contentEncoding.?);
}
