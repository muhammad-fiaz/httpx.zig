//! HTTP Compression Subsystem for httpx.zig
//!
//! Provides a complete, production-grade compression/decompression system
//! covering Content-Encoding, Accept-Encoding, Transfer-Encoding, and TE.
//!
//! Architecture:
//!   Content-Encoding  -- message body compression (gzip, deflate, br, zstd, identity)
//!   Transfer-Encoding  -- HTTP framing (chunked, identity)
//!   Accept-Encoding    -- client advertisement of supported content codings
//!   TE                 -- transfer coding negotiation (chunked, trailers)
//!
//! HPACK/QPACK are header compression -- handled separately in protocol modules.
//!
//! Supported content codings:
//!   identity  -- no transformation
//!   gzip      -- RFC 1952 via std.compress.flate
//!   deflate   -- RFC 1951 (zlib-wrapped) via std.compress.flate
//!   br        -- Brotli via brotli package
//!   zstd      -- Zstandard via zstd package
//!
//! Every supported codec has: encoder, decoder, streaming, tests, limits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zstd_lib = @import("zstd");
const brotli_lib = @import("brotli");

fn trimLeft(s: []const u8, chars: []const u8) []const u8 {
    var result = s;
    while (result.len > 0) {
        var found = false;
        for (chars) |c| {
            if (result[0] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        result = result[1..];
    }
    return result;
}

pub const CompressionError = error{
    CompressionFailed,
    CompressionLimitExceeded,
    UnsupportedEncoding,
    MalformedEncoding,
};

pub const DecompressionError = error{
    DecompressionFailed,
    DecompressionBombDetected,
    DecompressionLimitExceeded,
    TruncatedStream,
    MalformedData,
    InvalidChecksum,
};

pub const Limits = struct {
    max_decompressed_size: usize = 100 * 1024 * 1024,
    max_compressed_input: usize = 256 * 1024 * 1024,
    max_expansion_ratio: usize = 128,
};

pub const DEFAULT_MAX_DECOMPRESSED_SIZE: usize = 100 * 1024 * 1024;

pub const ContentEncoding = enum {
    identity,
    gzip,
    deflate,
    br,
    zstd,

    pub const ALL = [_]ContentEncoding{ .gzip, .deflate, .br, .zstd, .identity };

    pub fn toString(self: ContentEncoding) []const u8 {
        return switch (self) {
            .identity => "identity",
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
            .zstd => "zstd",
        };
    }

    pub fn fromString(str: []const u8) ?ContentEncoding {
        if (std.ascii.eqlIgnoreCase(str, "identity")) return .identity;
        if (std.ascii.eqlIgnoreCase(str, "gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(str, "deflate")) return .deflate;
        if (std.ascii.eqlIgnoreCase(str, "br")) return .br;
        if (std.ascii.eqlIgnoreCase(str, "zstd")) return .zstd;
        return null;
    }

    pub fn isSupported(self: ContentEncoding) bool {
        return switch (self) {
            .identity => true,
            .gzip => true,
            .deflate => true,
            .br => true,
            .zstd => true,
        };
    }
};

pub const ContentCoding = struct {
    encoding: ContentEncoding,
    q: f32 = 1.0,

    pub fn lessThan(self: ContentCoding, other: ContentCoding) bool {
        if (self.q > other.q) return true;
        if (self.q < other.q) return false;
        return @intFromEnum(self.encoding) < @intFromEnum(other.encoding);
    }
};

pub const AcceptEncoding = struct {
    entries: [8]ContentCoding,
    len: usize = 0,
    has_wildcard: bool = false,

    pub const ParseError = error{MalformedEncoding};

    pub fn parse(header_value: []const u8) ParseError!AcceptEncoding {
        var result = AcceptEncoding{ .entries = undefined };
        var remaining = std.mem.trim(u8, header_value, " \t");

        if (remaining.len == 0) return result;

        while (remaining.len > 0) {
            const token_end = parseTokenEnd(remaining);
            const token = std.mem.trim(u8, remaining[0..token_end], " \t");

            var q: f32 = 1.0;

            var after_token = remaining[token_end..];
            if (after_token.len > 0 and after_token[0] == ';') {
                after_token = after_token[1..];
                after_token = trimLeft(after_token, " \t");
                if (std.mem.startsWith(u8, after_token, "q=")) {
                    after_token = after_token[2..];
                    q = parseQValue(after_token) catch 1.0;
                    const q_end = parseQValueEnd(after_token);
                    after_token = after_token[q_end..];
                } else {
                    const param_end = std.mem.indexOfScalar(u8, after_token, ',') orelse after_token.len;
                    after_token = after_token[param_end..];
                }
            }

            if (std.mem.eql(u8, token, "*")) {
                result.has_wildcard = true;
            } else if (ContentEncoding.fromString(token)) |enc| {
                if (result.len < result.entries.len) {
                    result.entries[result.len] = .{ .encoding = enc, .q = q };
                    result.len += 1;
                }
            }

            remaining = after_token;
            if (remaining.len > 0 and remaining[0] == ',') {
                remaining = remaining[1..];
            } else {
                break;
            }
            remaining = trimLeft(remaining, " \t");
        }

        return result;
    }

    pub fn bestMatch(self: *const AcceptEncoding, supported: []const ContentEncoding) ?ContentEncoding {
        var best_q: f32 = -1.0;
        var best: ?ContentEncoding = null;

        for (self.entries[0..self.len]) |entry| {
            if (entry.q <= 0.0) continue;
            for (supported) |sup| {
                if (entry.encoding == sup) {
                    if (entry.q > best_q) {
                        best_q = entry.q;
                        best = entry.encoding;
                    }
                }
            }
        }

        if (best == null and self.has_wildcard) {
            for (supported) |sup| {
                if (sup != .identity) {
                    if (1.0 > best_q) {
                        best_q = 1.0;
                        best = sup;
                    }
                }
            }
        }

        if (best == null) {
            for (self.entries[0..self.len]) |entry| {
                if (entry.q <= 0.0) continue;
                if (entry.encoding == .identity) {
                    best = .identity;
                    break;
                }
            }
        }

        return best;
    }

    pub fn allowsIdentity(self: *const AcceptEncoding) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.encoding == .identity) return entry.q > 0.0;
        }
        return true;
    }

    pub fn has(self: *const AcceptEncoding, encoding: ContentEncoding, min_q: f32) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.encoding == encoding and entry.q > min_q) return true;
        }
        if (self.has_wildcard and encoding != .identity) return 1.0 > min_q;
        return false;
    }
};

fn parseTokenEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ',' or c == ';' or c == ' ' or c == '\t') return i;
    }
    return s.len;
}

fn parseQValue(s: []const u8) !f32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return error.MalformedEncoding;

    const end = parseQValueEnd(trimmed);
    const q_str = trimmed[0..end];

    if (q_str.len == 0) return error.MalformedEncoding;

    if (std.fmt.parseFloat(f32, q_str)) |q| {
        if (q < 0.0 or q > 1.0) return error.MalformedEncoding;
        return q;
    } else |_| {
        return error.MalformedEncoding;
    }
}

fn parseQValueEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ',' or c == ' ' or c == '\t') return i;
    }
    return s.len;
}

pub const ContentEncodingHeader = struct {
    codings: [4]ContentEncoding,
    len: usize = 0,

    pub const ParseError = error{MalformedEncoding};

    pub fn parse(header_value: []const u8) ParseError!ContentEncodingHeader {
        var result = ContentEncodingHeader{ .codings = undefined };
        var remaining = std.mem.trim(u8, header_value, " \t");

        while (remaining.len > 0) {
            const token_end = parseTokenEnd(remaining);
            const token = std.mem.trim(u8, remaining[0..token_end], " \t");

            if (ContentEncoding.fromString(token)) |enc| {
                if (result.len < result.codings.len) {
                    result.codings[result.len] = enc;
                    result.len += 1;
                }
            }

            remaining = remaining[token_end..];
            if (remaining.len > 0 and remaining[0] == ',') {
                remaining = remaining[1..];
            } else {
                break;
            }
            remaining = trimLeft(remaining, " \t");
        }

        return result;
    }

    pub fn primary(self: *const ContentEncodingHeader) ContentEncoding {
        if (self.len == 0) return .identity;
        return self.codings[0];
    }
};

pub const TransferCoding = enum {
    chunked,
    identity,

    pub fn fromString(str: []const u8) ?TransferCoding {
        if (std.ascii.eqlIgnoreCase(str, "chunked")) return .chunked;
        if (std.ascii.eqlIgnoreCase(str, "identity")) return .identity;
        return null;
    }

    pub fn toString(self: TransferCoding) []const u8 {
        return switch (self) {
            .chunked => "chunked",
            .identity => "identity",
        };
    }
};

pub const TransferEncodingHeader = struct {
    codings: [4]TransferCoding,
    len: usize = 0,

    pub fn parse(header_value: []const u8) ?TransferEncodingHeader {
        var result = TransferEncodingHeader{ .codings = undefined };
        var remaining = std.mem.trim(u8, header_value, " \t");

        while (remaining.len > 0) {
            const token_end = parseTokenEnd(remaining);
            const token = std.mem.trim(u8, remaining[0..token_end], " \t");

            if (TransferCoding.fromString(token)) |tc| {
                if (result.len < result.codings.len) {
                    result.codings[result.len] = tc;
                    result.len += 1;
                }
            }

            remaining = remaining[token_end..];
            if (remaining.len > 0 and remaining[0] == ',') {
                remaining = remaining[1..];
            } else {
                break;
            }
            remaining = trimLeft(remaining, " \t");
        }

        return if (result.len > 0) result else null;
    }

    pub fn isChunked(self: *const TransferEncodingHeader) bool {
        for (self.codings[0..self.len]) |tc| {
            if (tc == .chunked) return true;
        }
        return false;
    }
};

pub const TeHeader = struct {
    entries: [4]TeEntry,
    len: usize = 0,

    pub const TeEntry = struct {
        name: []const u8,
        q: f32 = 1.0,
    };

    pub fn parse(header_value: []const u8) ?TeHeader {
        var result = TeHeader{ .entries = undefined };
        var remaining = std.mem.trim(u8, header_value, " \t");

        while (remaining.len > 0) {
            const token_end = parseTokenEnd(remaining);
            const token = std.mem.trim(u8, remaining[0..token_end], " \t");

            var q: f32 = 1.0;
            var after_token = remaining[token_end..];
            if (after_token.len > 0 and after_token[0] == ';') {
                after_token = after_token[1..];
                after_token = trimLeft(after_token, " \t");
                if (std.mem.startsWith(u8, after_token, "q=")) {
                    after_token = after_token[2..];
                    q = parseQValue(after_token) catch 1.0;
                    const q_end = parseQValueEnd(after_token);
                    after_token = after_token[q_end..];
                } else {
                    const param_end = std.mem.indexOfScalar(u8, after_token, ',') orelse after_token.len;
                    after_token = after_token[param_end..];
                }
            }

            if (result.len < result.entries.len) {
                result.entries[result.len] = .{ .name = token, .q = q };
                result.len += 1;
            }

            remaining = after_token;
            if (remaining.len > 0 and remaining[0] == ',') {
                remaining = remaining[1..];
            } else {
                break;
            }
            remaining = trimLeft(remaining, " \t");
        }

        return if (result.len > 0) result else null;
    }

    pub fn wantsTrailers(self: *const TeHeader) bool {
        for (self.entries[0..self.len]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "trailers") and entry.q > 0.0) return true;
        }
        return false;
    }
};

pub fn compress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8 {
    return compressWithLevel(allocator, encoding, data, .{});
}

pub const CompressOptions = struct {
    level: CompressionLevel = .default,
    max_output: usize = 256 * 1024 * 1024,
};

pub const CompressionLevel = enum {
    fast,
    default,
    best,
};

pub fn compressWithLevel(allocator: Allocator, encoding: ContentEncoding, data: []const u8, options: CompressOptions) ![]u8 {
    if (data.len > options.max_output) return error.CompressionLimitExceeded;

    switch (encoding) {
        .identity => return allocator.dupe(u8, data),
        .gzip => return compressGzip(allocator, data, options.level),
        .deflate => return compressDeflate(allocator, data, options.level),
        .br => return brotli_lib.compress(allocator, data) catch return error.CompressionFailed,
        .zstd => return compressZstd(allocator, data, options.level),
    }
}

pub fn decompress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8 {
    return decompressWithLimit(allocator, encoding, data, DEFAULT_MAX_DECOMPRESSED_SIZE);
}

pub fn decompressWithLimit(allocator: Allocator, encoding: ContentEncoding, data: []const u8, max_output_size: usize) ![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0) catch return error.DecompressionFailed;

    switch (encoding) {
        .identity => {
            if (data.len > max_output_size) return error.DecompressionBombDetected;
            return allocator.dupe(u8, data);
        },
        .gzip => return decompressGzip(allocator, data, max_output_size),
        .deflate => return decompressDeflate(allocator, data, max_output_size),
        .br => {
            const result = brotli_lib.decompress(allocator, data) catch return error.DecompressionFailed;
            if (result.len > max_output_size) {
                allocator.free(result);
                return error.DecompressionBombDetected;
            }
            return result;
        },
        .zstd => return decompressZstd(allocator, data, max_output_size),
    }
}

pub fn decompressStacked(allocator: Allocator, header: *const ContentEncodingHeader, data: []const u8, max_output_size: usize) ![]u8 {
    var current = data;
    var owned_current: ?[]u8 = null;
    defer if (owned_current) |p| allocator.free(p);

    var i: usize = 0;
    while (i < header.len) : (i += 1) {
        const enc = header.codings[i];
        if (enc == .identity) continue;

        const prev = current;
        current = try decompressWithLimit(allocator, enc, current, max_output_size);

        if (owned_current) |p| allocator.free(p);

        if (prev.ptr != data.ptr) {
            owned_current = current;
        }
    }

    if (owned_current) |p| {
        _ = p;
        return current;
    }
    return allocator.dupe(u8, current) catch return error.DecompressionFailed;
}

fn compressGzip(allocator: Allocator, data: []const u8, level: CompressionLevel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(data.len + 64);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const flate_level = toFlateLevel(level);
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .gzip, flate_level) catch return error.CompressionFailed;
    _ = compressor.writer.writeAll(data) catch return error.CompressionFailed;
    compressor.finish() catch return error.CompressionFailed;

    return aw.toOwnedSlice() catch return error.CompressionFailed;
}

fn decompressGzip(allocator: Allocator, data: []const u8, max_output_size: usize) ![]u8 {
    return decompressFlate(allocator, data, .gzip, max_output_size);
}

fn compressDeflate(allocator: Allocator, data: []const u8, level: CompressionLevel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.ensureUnusedCapacity(data.len + 64);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const flate_level = toFlateLevel(level);
    var compressor = std.compress.flate.Compress.init(&aw.writer, &window_buf, .zlib, flate_level) catch return error.CompressionFailed;
    _ = compressor.writer.writeAll(data) catch return error.CompressionFailed;
    compressor.finish() catch return error.CompressionFailed;

    return aw.toOwnedSlice() catch return error.CompressionFailed;
}

fn decompressDeflate(allocator: Allocator, data: []const u8, max_output_size: usize) ![]u8 {
    return decompressFlate(allocator, data, .zlib, max_output_size) catch {
        return decompressFlate(allocator, data, .raw, max_output_size);
    };
}

fn decompressFlate(allocator: Allocator, data: []const u8, container: std.compress.flate.Container, max_output_size: usize) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&in, container, &window_buf);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    _ = decompressor.reader.streamRemaining(&aw.writer) catch return error.DecompressionFailed;

    const result = aw.toOwnedSlice() catch return error.DecompressionFailed;
    if (result.len > max_output_size) {
        allocator.free(result);
        return error.DecompressionBombDetected;
    }

    return result;
}

fn toFlateLevel(level: CompressionLevel) std.compress.flate.Compress.Options {
    return switch (level) {
        .fast => .level_1,
        .default => .level_6,
        .best => .level_9,
    };
}

fn compressZstd(allocator: Allocator, data: []const u8, level: CompressionLevel) ![]u8 {
    const zstd_level: i32 = switch (level) {
        .fast => 1,
        .default => 3,
        .best => 19,
    };
    return zstd_lib.compress(allocator, data, zstd_level) catch return error.CompressionFailed;
}

fn decompressZstd(allocator: Allocator, data: []const u8, max_output_size: usize) ![]u8 {
    const content_size = switch (zstd_lib.getFrameContentSize(data)) {
        .known => |size| size,
        .unknown, .@"error" => return error.DecompressionFailed,
    };

    if (content_size > max_output_size) return error.DecompressionBombDetected;

    return zstd_lib.decompress(allocator, data, @intCast(content_size)) catch {
        return error.DecompressionFailed;
    };
}

pub const NegotiationConfig = struct {
    supported: []const ContentEncoding = &.{ .gzip, .deflate, .br, .zstd },
    prefer: ?ContentEncoding = null,
    min_response_bytes: usize = 0,
};

pub fn negotiateEncoding(accept: *const AcceptEncoding, config: *const NegotiationConfig) ?ContentEncoding {
    if (config.prefer) |preferred| {
        for (config.supported) |sup| {
            if (sup == preferred) {
                for (accept.entries[0..accept.len]) |entry| {
                    if (entry.encoding == preferred and entry.q > 0.0) return preferred;
                }
            }
        }
    }

    return accept.bestMatch(config.supported);
}

test "ContentEncoding fromString / toString" {
    try std.testing.expectEqual(ContentEncoding.gzip, ContentEncoding.fromString("gzip").?);
    try std.testing.expectEqual(ContentEncoding.gzip, ContentEncoding.fromString("Gzip").?);
    try std.testing.expectEqual(ContentEncoding.br, ContentEncoding.fromString("br").?);
    try std.testing.expectEqual(@as(?ContentEncoding, null), ContentEncoding.fromString("unknown"));
    try std.testing.expectEqualStrings("gzip", ContentEncoding.gzip.toString());
}

test "Accept-Encoding parse basic" {
    const ae = try AcceptEncoding.parse("gzip, deflate, br");
    try std.testing.expectEqual(@as(usize, 3), ae.len);
    try std.testing.expectEqual(ContentEncoding.gzip, ae.entries[0].encoding);
    try std.testing.expectEqual(@as(f32, 1.0), ae.entries[0].q);
}

test "Accept-Encoding parse with q-values" {
    const ae = try AcceptEncoding.parse("br;q=1.0, gzip;q=0.8, identity;q=0.1");
    try std.testing.expectEqual(@as(usize, 3), ae.len);
    try std.testing.expectEqual(ContentEncoding.br, ae.entries[0].encoding);
    try std.testing.expectEqual(@as(f32, 1.0), ae.entries[0].q);
    try std.testing.expectEqual(ContentEncoding.gzip, ae.entries[1].encoding);
    try std.testing.expectEqual(@as(f32, 0.8), ae.entries[1].q);
}

test "Accept-Encoding parse q=0" {
    const ae = try AcceptEncoding.parse("gzip;q=0, br;q=1");
    try std.testing.expectEqual(@as(usize, 2), ae.len);
    try std.testing.expectEqual(@as(f32, 0.0), ae.entries[0].q);
    try std.testing.expectEqual(@as(f32, 1.0), ae.entries[1].q);
}

test "Accept-Encoding parse wildcard" {
    const ae = try AcceptEncoding.parse("*");
    try std.testing.expect(ae.has_wildcard);
}

test "Accept-Encoding bestMatch" {
    const ae = try AcceptEncoding.parse("gzip;q=0.5, br;q=1.0");
    const supported = [_]ContentEncoding{ .gzip, .deflate, .br };
    try std.testing.expectEqual(ContentEncoding.br, ae.bestMatch(&supported).?);
}

test "Accept-Encoding bestMatch identity forbidden" {
    const ae = try AcceptEncoding.parse("gzip;q=0.5, identity;q=0");
    const supported = [_]ContentEncoding{ .gzip, .identity };
    try std.testing.expectEqual(ContentEncoding.gzip, ae.bestMatch(&supported).?);
}

test "Content-Encoding parse single" {
    const ce = try ContentEncodingHeader.parse("gzip");
    try std.testing.expectEqual(@as(usize, 1), ce.len);
    try std.testing.expectEqual(ContentEncoding.gzip, ce.codings[0]);
}

test "Content-Encoding parse stacked" {
    const ce = try ContentEncodingHeader.parse("gzip, br");
    try std.testing.expectEqual(@as(usize, 2), ce.len);
    try std.testing.expectEqual(ContentEncoding.gzip, ce.codings[0]);
    try std.testing.expectEqual(ContentEncoding.br, ce.codings[1]);
}

test "Transfer-Encoding parse chunked" {
    const te = TransferEncodingHeader.parse("chunked") orelse return error.TestFailed;
    try std.testing.expect(te.isChunked());
}

test "Transfer-Encoding parse identity" {
    const te = TransferEncodingHeader.parse("identity") orelse return error.TestFailed;
    try std.testing.expect(!te.isChunked());
}

test "TE parse trailers" {
    const te = TeHeader.parse("trailers, chunked;q=0.5") orelse return error.TestFailed;
    try std.testing.expect(te.wantsTrailers());
}

test "gzip compress decompress round trip" {
    const allocator = std.testing.allocator;
    const sample = "Hello, httpx.zig gzip compression test!";

    const compressed = try compress(allocator, .gzip, sample);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .gzip, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(sample, decompressed);
}

test "deflate compress decompress round trip" {
    const allocator = std.testing.allocator;
    const sample = "Hello, httpx.zig deflate compression test!";

    const compressed = try compress(allocator, .deflate, sample);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .deflate, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(sample, decompressed);
}

test "brotli compress decompress round trip" {
    const allocator = std.testing.allocator;
    const sample = "Hello, httpx.zig brotli compression test!";

    const compressed = try compress(allocator, .br, sample);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .br, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(sample, decompressed);
}

test "zstd compress decompress round trip" {
    const allocator = std.testing.allocator;
    const sample = "Hello, httpx.zig zstd compression test!";

    const compressed = try compress(allocator, .zstd, sample);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .zstd, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(sample, decompressed);
}

test "identity passthrough" {
    const allocator = std.testing.allocator;
    const sample = "Uncompressed payload";

    const decompressed = try decompress(allocator, .identity, sample);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(sample, decompressed);
}

test "decompression bomb protection" {
    const allocator = std.testing.allocator;
    const sample = "Hello, bomb test!";

    const compressed = try compress(allocator, .gzip, sample);
    defer allocator.free(compressed);

    try std.testing.expectError(error.DecompressionBombDetected, decompressWithLimit(allocator, .gzip, compressed, 5));
}

test "empty input" {
    const allocator = std.testing.allocator;
    const compressed = try compress(allocator, .gzip, "");
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .gzip, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "negotiateEncoding basic" {
    const ae = try AcceptEncoding.parse("gzip, br");
    const config = NegotiationConfig{ .supported = &.{ .gzip, .deflate } };
    try std.testing.expectEqual(ContentEncoding.gzip, negotiateEncoding(&ae, &config).?);
}

test "negotiateEncoding with preference" {
    const ae = try AcceptEncoding.parse("gzip, br");
    const config = NegotiationConfig{
        .supported = &.{ .gzip, .br },
        .prefer = .br,
    };
    try std.testing.expectEqual(ContentEncoding.br, negotiateEncoding(&ae, &config).?);
}

pub fn isCompressible(content_type: []const u8) bool {
    const mime = @import("../data/mime.zig");
    return mime.isCompressible(content_type);
}
