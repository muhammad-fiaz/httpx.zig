// Content compression: negotiation + encode/decode for gzip, deflate, zstd, brotli.
//
// Uses:
//   * std.compress.flate for gzip + zlib (Zig builtin)
//   * zstd dependency for zstd
//   * brotli dependency for br
//
// Negotiation follows RFC 9110 section 12.5.3 (Accept-Encoding).

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const zstd_mod = @import("zstd");
const brotli_mod = @import("brotli");

pub const Error = error{
    UnsupportedEncoding,
    CorruptData,
    OutOfMemory,
    DecompressedTooLarge,
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
        if (std.ascii.eqlIgnoreCase(tok, "gzip")) return .gzip;
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
    const q = std.fmt.parseFloat(f32, text) catch return 0;
    if (!std.math.isFinite(q) or q < 0 or q > 1) return 0;
    return q;
}

/// Parses an Accept-Encoding header value into weighted entries.
/// Handles q-values and "*" wildcard.
pub fn parseAcceptEncoding(allocator: Allocator, header_value: []const u8) ![]ParsedEncoding {
    var results = std.ArrayList(ParsedEncoding).empty;
    errdefer results.deinit(allocator);

    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;

        var seg_it = std.mem.splitScalar(u8, part, ';');
        const tok = std.mem.trim(u8, seg_it.next() orelse continue, " \t");
        var q: f32 = 1.0;

        if (seg_it.next()) |qpart_raw| {
            const qpart = std.mem.trim(u8, qpart_raw, " \t");
            if (std.ascii.startsWithIgnoreCase(qpart, "q=")) {
                q = parseQuality(qpart[2..]);
            }
        }

        if (tok.len == 1 and tok[0] == '*') {
            // Wildcard: expand to all codings not explicitly listed
            inline for (@typeInfo(Encoding).@"enum".fields) |f| {
                const enc: Encoding = @enumFromInt(f.value);
                try results.append(allocator, .{ .encoding = enc, .q = q });
            }
            continue;
        }

        if (Encoding.fromToken(tok)) |enc| {
            try results.append(allocator, .{ .encoding = enc, .q = q });
        }
        // Unknown tokens are ignored per spec
    }
    return results.toOwnedSlice(allocator);
}

/// Picks the best encoding we support from the client's Accept-Encoding.
pub fn negotiate(header_value: []const u8) Encoding {
    var explicit: [5]?f32 = .{ null, null, null, null, null };
    var wildcard: ?f32 = null;
    var has_entry = false;

    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;

        var seg_it = std.mem.splitScalar(u8, part, ';');
        has_entry = true;
        const tok = std.mem.trim(u8, seg_it.next() orelse continue, " \t");
        var q: f32 = 1.0;
        if (seg_it.next()) |qp_raw| {
            const qp = std.mem.trim(u8, qp_raw, " \t");
            if (std.ascii.startsWithIgnoreCase(qp, "q=")) {
                q = parseQuality(qp[2..]);
            }
        }
        if (Encoding.fromToken(tok)) |enc| {
            explicit[@intFromEnum(enc)] = q;
        } else if (tok.len == 1 and tok[0] == '*') {
            wildcard = q;
        }
    }

    var best: Encoding = .identity;
    var best_q: f32 = 0.0;
    var found = false;
    inline for (@typeInfo(Encoding).@"enum".fields) |field| {
        const enc: Encoding = @enumFromInt(field.value);
        const q = explicit[@intFromEnum(enc)] orelse wildcard orelse
            if (enc == .identity and !has_entry) @as(f32, 1.0) else @as(f32, 0.0);
        if (q > 0 and (!found or q > best_q or (q == best_q and preference(enc) > preference(best)))) {
            best = enc;
            best_q = q;
            found = true;
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

/// Compresses with the given encoding.
pub fn compress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8 {
    switch (encoding) {
        .zstd => return zstd_mod.compress(allocator, data) catch Error.CorruptData,
        .br => return brotli_mod.compress(allocator, data) catch Error.CorruptData,
        .identity => return allocator.dupe(u8, data),
        .gzip, .deflate => return flateCompress(allocator, encoding == .gzip, data),
    }
}

fn flateDecompressImpl(allocator: Allocator, container: flate.Container, data: []const u8) ![]u8 {
    var in_reader = std.Io.Reader.fixed(data);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var decomp = flate.Decompress.init(&in_reader, container, window);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    decomp.reader.appendRemainingUnlimited(allocator, &out) catch return Error.CorruptData;
    return out.toOwnedSlice(allocator);
}

fn flateCompress(allocator: Allocator, gzip_container: bool, data: []const u8) ![]u8 {
    const initial_capacity = std.math.add(usize, data.len, 64) catch return Error.OutOfMemory;
    var output = std.Io.Writer.Allocating.initCapacity(allocator, initial_capacity) catch
        return Error.OutOfMemory;
    defer output.deinit();
    const history = allocator.alloc(u8, flate.max_window_len * 2) catch return Error.OutOfMemory;
    defer allocator.free(history);

    var compressor = flate.Compress.init(
        &output.writer,
        history,
        if (gzip_container) .gzip else .zlib,
        .default,
    ) catch return Error.CorruptData;
    compressor.writer.writeAll(data) catch return Error.CorruptData;
    flate.Compress.finish(&compressor) catch return Error.CorruptData;
    return output.toOwnedSlice() catch return Error.OutOfMemory;
}

fn flateDecompress(allocator: Allocator, is_gzip: bool, data: []const u8) ![]u8 {
    return flateDecompressImpl(allocator, if (is_gzip) .gzip else .zlib, data);
}

/// Decompresses with the given encoding.
pub fn decompress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8 {
    switch (encoding) {
        .zstd => return zstd_mod.decompress(allocator, data) catch Error.CorruptData,
        .br => return brotli_mod.decompress(allocator, data) catch Error.CorruptData,
        .identity => return allocator.dupe(u8, data),
        .gzip, .deflate => return flateDecompress(allocator, encoding == .gzip, data),
    }
}

/// Decompresses content while rejecting expansion beyond `max_size`.
/// This is intended for response bodies and other untrusted compressed input.
pub fn decompressLimited(allocator: Allocator, encoding: Encoding, data: []const u8, max_size: usize) ![]u8 {
    if (max_size == 0) return Error.DecompressedTooLarge;
    return switch (encoding) {
        .identity => if (data.len > max_size) Error.DecompressedTooLarge else allocator.dupe(u8, data),
        .zstd => {
            const bound = zstd_mod.decompressBound(data) catch return Error.CorruptData;
            if (bound > max_size) return Error.DecompressedTooLarge;
            return zstd_mod.decompress(allocator, data) catch Error.CorruptData;
        },
        .br => brotliDecompressLimited(allocator, data, max_size),
        .gzip, .deflate => flateDecompressLimited(allocator, encoding == .gzip, data, max_size),
    };
}

fn brotliDecompressLimited(allocator: Allocator, data: []const u8, max_size: usize) ![]u8 {
    var capacity: usize = @min(max_size, @max(@as(usize, 4096), data.len *| 4));
    while (true) {
        var decoder = brotli_mod.Decoder.init(allocator, .{});
        defer decoder.deinit();
        var input: []const u8 = data;
        var output = try allocator.alloc(u8, capacity);
        var available = output[0..];
        var total: u64 = 0;
        switch (decoder.decompressStream(&input, &available, &total)) {
            .success => {
                const written: usize = @intCast(total);
                if (written > max_size) {
                    allocator.free(output);
                    return Error.DecompressedTooLarge;
                }
                return output[0..written];
            },
            .needs_more_output => {
                allocator.free(output);
                if (capacity == max_size) return Error.DecompressedTooLarge;
                capacity = @min(max_size, capacity *| 2);
            },
            else => {
                allocator.free(output);
                return Error.CorruptData;
            },
        }
    }
}

fn flateDecompressLimited(allocator: Allocator, is_gzip: bool, data: []const u8, max_size: usize) ![]u8 {
    const result = flateDecompress(allocator, is_gzip, data) catch |err| return err;
    if (result.len > max_size) {
        allocator.free(result);
        return Error.DecompressedTooLarge;
    }
    return result;
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
    try std.testing.expectEqual(Encoding.zstd, negotiate("gzip, br, zstd"));
    try std.testing.expectEqual(Encoding.br, negotiate("gzip, br"));
    // identity defaults to q=1 so it outranks gzip;q=0.9 (RFC 9110 section 12.5.3)
    try std.testing.expectEqual(Encoding.identity, negotiate("gzip;q=0.9, identity"));
    try std.testing.expectEqual(Encoding.gzip, negotiate("gzip;q=0.9"));
    try std.testing.expectEqual(Encoding.identity, negotiate(""));
}

test "negotiate respects q=0 rejection" {
    try std.testing.expectEqual(Encoding.identity, negotiate("zstd;q=0"));
}

test "negotiate rejects malformed and out-of-range quality values" {
    try std.testing.expectEqual(Encoding.identity, negotiate("gzip;q=bogus"));
    try std.testing.expectEqual(Encoding.identity, negotiate("br;q=1.1"));
    try std.testing.expectEqual(Encoding.identity, negotiate("zstd;q=-0.1"));
}

test "negotiate applies wildcard to unspecified codings" {
    try std.testing.expectEqual(Encoding.zstd, negotiate("*;q=0.4"));
    try std.testing.expectEqual(Encoding.identity, negotiate("*;q=0, identity;q=0"));
    try std.testing.expectEqual(Encoding.gzip, negotiate("*;q=0.4, zstd;q=0, br;q=0"));
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

    const compressed = try compress(a, .zstd, original);
    defer a.free(compressed);
    try std.testing.expectError(Error.DecompressedTooLarge, decompressLimited(a, .zstd, compressed, 4));
    const restored = try decompressLimited(a, .zstd, compressed, original.len);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "limited brotli decompression grows within the configured bound" {
    const a = std.testing.allocator;
    const original = "brotli bounded output " ** 512;
    const compressed = try compress(a, .br, original);
    defer a.free(compressed);
    try std.testing.expectError(Error.DecompressedTooLarge, decompressLimited(a, .br, compressed, original.len - 1));
    const restored = try decompressLimited(a, .br, compressed, original.len);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}
