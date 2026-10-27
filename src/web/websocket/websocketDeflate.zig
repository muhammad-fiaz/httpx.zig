//! RFC 7692: Compression Extensions for WebSocket (permessage-deflate).
//!
//! Provides negotiation of the "permessage-deflate" extension, raw DEFLATE
//! compression with trailing 0x00 0x00 0xFF 0xFF removal, and bounded
//! decompression with tail reconstruction and decompression bomb defenses.
//!
//! References:
//!   - RFC 7692: Compression Extensions for WebSocket
//!   - RFC 1951: DEFLATE Compressed Data Format Specification

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const EXTENSION_NAME = "permessage-deflate";
pub const TAIL_TRAILER = [_]u8{ 0x00, 0x00, 0xFF, 0xFF };
pub const DEFAULT_MAX_DECOMPRESSED_SIZE: usize = 16 * 1024 * 1024;

pub const DeflateError = error{
    CorruptData,
    DecompressedTooLarge,
    OutOfMemory,
    InvalidExtensionHeader,
};

pub const PermessageDeflateConfig = struct {
    clientNoContextTakeover: bool = true,
    serverNoContextTakeover: bool = true,
    clientMaxWindowBits: ?u4 = null,
    serverMaxWindowBits: ?u4 = null,
    maxDecompressedSize: usize = DEFAULT_MAX_DECOMPRESSED_SIZE,
};

/// Formats a Sec-WebSocket-Extensions client offer string for permessage-deflate.
pub fn formatOffer(allocator: Allocator, config: PermessageDeflateConfig) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, EXTENSION_NAME);
    if (config.clientNoContextTakeover) {
        try list.appendSlice(allocator, "; client_no_context_takeover");
    }
    if (config.serverNoContextTakeover) {
        try list.appendSlice(allocator, "; server_no_context_takeover");
    }
    if (config.clientMaxWindowBits) |bits| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "; client_max_window_bits={d}", .{bits});
        try list.appendSlice(allocator, s);
    }
    if (config.serverMaxWindowBits) |bits| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "; server_max_window_bits={d}", .{bits});
        try list.appendSlice(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

/// Parses a Sec-WebSocket-Extensions header line and extracts permessage-deflate configuration.
pub fn parseNegotiatedExtension(headerValue: []const u8) ?PermessageDeflateConfig {
    var entries = std.mem.splitScalar(u8, headerValue, ',');
    while (entries.next()) |rawEntry| {
        const entry = std.mem.trim(u8, rawEntry, " \t\r\n");
        if (entry.len == 0) continue;

        var tokens = std.mem.splitScalar(u8, entry, ';');
        const extName = std.mem.trim(u8, tokens.next() orelse "", " \t");
        if (!std.ascii.eqlIgnoreCase(extName, EXTENSION_NAME)) continue;

        var cfg = PermessageDeflateConfig{};
        while (tokens.next()) |rawParam| {
            const param = std.mem.trim(u8, rawParam, " \t");
            if (param.len == 0) continue;

            const eqIdx = std.mem.indexOfScalar(u8, param, '=');
            const key = if (eqIdx) |idx| std.mem.trim(u8, param[0..idx], " \t") else param;
            const val = if (eqIdx) |idx| std.mem.trim(u8, param[idx + 1 ..], " \t\"") else "";

            if (std.ascii.eqlIgnoreCase(key, "client_no_context_takeover")) {
                cfg.clientNoContextTakeover = true;
            } else if (std.ascii.eqlIgnoreCase(key, "server_no_context_takeover")) {
                cfg.serverNoContextTakeover = true;
            } else if (std.ascii.eqlIgnoreCase(key, "client_max_window_bits")) {
                if (val.len > 0) {
                    cfg.clientMaxWindowBits = std.fmt.parseInt(u4, val, 10) catch null;
                }
            } else if (std.ascii.eqlIgnoreCase(key, "server_max_window_bits")) {
                if (val.len > 0) {
                    cfg.serverMaxWindowBits = std.fmt.parseInt(u4, val, 10) catch null;
                }
            }
        }
        return cfg;
    }
    return null;
}

/// Compresses a message payload according to RFC 7692:
/// raw DEFLATE with the trailing 0x00 0x00 0xFF 0xFF octets stripped.
pub fn compressMessage(allocator: Allocator, data: []const u8) DeflateError![]u8 {
    const initialCapacity = std.math.add(usize, data.len, 64) catch return DeflateError.OutOfMemory;
    var output = std.Io.Writer.Allocating.initCapacity(allocator, initialCapacity) catch
        return DeflateError.OutOfMemory;
    defer output.deinit();

    const history = allocator.alloc(u8, flate.max_window_len * 2) catch return DeflateError.OutOfMemory;
    defer allocator.free(history);

    var compressor = flate.Compress.init(
        &output.writer,
        history,
        .raw,
        .default,
    ) catch return DeflateError.CorruptData;

    compressor.writer.writeAll(data) catch return DeflateError.CorruptData;
    flate.Compress.finish(&compressor) catch return DeflateError.CorruptData;

    const compressed = output.toOwnedSlice() catch return DeflateError.OutOfMemory;

    // RFC 7692 Section 7.2.1: Strip the 4 octets 0x00 0x00 0xFF 0xFF from the end
    if (compressed.len >= 4 and std.mem.endsWith(u8, compressed, &TAIL_TRAILER)) {
        const strippedLen = compressed.len - 4;
        const result = allocator.alloc(u8, strippedLen) catch {
            allocator.free(compressed);
            return DeflateError.OutOfMemory;
        };
        @memcpy(result, compressed[0..strippedLen]);
        allocator.free(compressed);
        return result;
    }

    return compressed;
}

/// Decompresses an RFC 7692 message payload:
/// appends the 0x00 0x00 0xFF 0xFF trailer and decodes raw DEFLATE, bounded by maxSize.
pub fn decompressMessage(allocator: Allocator, data: []const u8, maxSize: usize) DeflateError![]u8 {
    // Reconstruct input with the trailing 0x00 0x00 0xFF 0xFF
    const totalInputLen = std.math.add(usize, data.len, 4) catch return DeflateError.OutOfMemory;
    const inputWithTail = allocator.alloc(u8, totalInputLen) catch return DeflateError.OutOfMemory;
    defer allocator.free(inputWithTail);

    @memcpy(inputWithTail[0..data.len], data);
    @memcpy(inputWithTail[data.len..], &TAIL_TRAILER);

    var inReader = std.Io.Reader.fixed(inputWithTail);
    const window = allocator.alloc(u8, flate.max_window_len) catch return DeflateError.OutOfMemory;
    defer allocator.free(window);

    var decomp = flate.Decompress.init(&inReader, .raw, window);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&buf) catch return DeflateError.CorruptData;
        if (n == 0) break;
        const newLen = std.math.add(usize, out.items.len, n) catch return DeflateError.DecompressedTooLarge;
        if (newLen > maxSize) return DeflateError.DecompressedTooLarge;
        out.appendSlice(allocator, buf[0..n]) catch return DeflateError.OutOfMemory;
    }

    return out.toOwnedSlice(allocator) catch return DeflateError.OutOfMemory;
}

// Tests

test "offer formatting and parsing" {
    const a = std.testing.allocator;
    const cfg = PermessageDeflateConfig{
        .clientNoContextTakeover = true,
        .serverNoContextTakeover = true,
        .clientMaxWindowBits = 15,
    };

    const offer = try formatOffer(a, cfg);
    defer a.free(offer);

    const parsed = parseNegotiatedExtension(offer);
    try std.testing.expect(parsed != null);
    try std.testing.expect(parsed.?.clientNoContextTakeover);
    try std.testing.expect(parsed.?.serverNoContextTakeover);
    try std.testing.expectEqual(@as(?u4, 15), parsed.?.clientMaxWindowBits);
}

test "compress and decompress roundtrip with trailer strip and reconstruction" {
    const a = std.testing.allocator;
    const original = "The quick brown fox jumps over the lazy dog. Repetition repetition repetition repetition!";

    const compressed = try compressMessage(a, original);
    defer a.free(compressed);

    // Verify trailing 0x00 0x00 0xFF 0xFF was stripped
    if (compressed.len >= 4) {
        try std.testing.expect(!std.mem.endsWith(u8, compressed, &TAIL_TRAILER));
    }

    const decompressed = try decompressMessage(a, compressed, DEFAULT_MAX_DECOMPRESSED_SIZE);
    defer a.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "decompression bomb bounds enforcement" {
    const a = std.testing.allocator;
    const largeOriginal: [4000]u8 = @splat('A');

    const compressed = try compressMessage(a, &largeOriginal);
    defer a.free(compressed);

    // Decompression with bound smaller than original must fail with DecompressedTooLarge
    try std.testing.expectError(DeflateError.DecompressedTooLarge, decompressMessage(a, compressed, 200));

    // Decompression with sufficient bound succeeds
    const decompressed = try decompressMessage(a, compressed, 5000);
    defer a.free(decompressed);
    try std.testing.expectEqualSlices(u8, &largeOriginal, decompressed);
}
