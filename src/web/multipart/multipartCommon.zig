//! Shared multipart validation and encoding helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Validates a boundary string per RFC 2046 Section 5.1.1.
pub fn validateBoundary(boundary: []const u8) bool {
    if (boundary.len == 0 or boundary.len > 70) return false;
    for (boundary) |c| {
        if (c >= 128) return false;
        if (!std.ascii.isAlphanumeric(c) and c != '\'' and c != '(' and c != ')' and
            c != '_' and c != '+' and c != '-' and c != ',' and c != '.' and
            c != '/' and c != ':' and c != '=' and c != '?')
            return false;
    }
    return true;
}

pub fn isToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return false,
            else => {},
        }
    }
    return true;
}

/// True when `value` can be written as a quoted-string after escaping `"` and `\`.
pub fn isQuotedStringSafe(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
        if (c < 0x20 and c != '\t') return false;
    }
    return true;
}

pub fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        if (c == '"' or c == '\\') try writer.writeByte('\\');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

/// Writes a header value, rejecting CR/LF/NUL and control characters.
pub fn writeHeaderValue(writer: anytype, value: []const u8) !void {
    if (!isHeaderValueSafe(value)) return error.InvalidHeaderValue;
    try writer.writeAll(value);
}

pub fn isHeaderValueSafe(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
        if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
    }
    return true;
}

/// RFC 8187 attr-char percent encoding.
pub fn percentEncode(writer: anytype, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        const attr = std.ascii.isAlphanumeric(c) or switch (c) {
            '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        if (attr) {
            try writer.writeByte(c);
        } else {
            try writer.writeAll(&[_]u8{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
}

pub fn percentDecode(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '%') {
            if (value.len - i < 3) return error.InvalidPercentEncoding;
            const hi = std.fmt.charToDigit(value[i + 1], 16) catch return error.InvalidPercentEncoding;
            const lo = std.fmt.charToDigit(value[i + 2], 16) catch return error.InvalidPercentEncoding;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Returns a filesystem-safe display name. The result never contains path
/// separators, control characters, or a leading dot.
pub fn safeFilename(allocator: Allocator, suggested: []const u8) ![]u8 {
    var base = suggested;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |idx| base = base[idx + 1 ..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (base) |c| {
        if (c >= 0x20 and c != 0x7f and c != '/' and c != '\\' and c != ':' and c != '*' and
            c != '?' and c != '"' and c != '<' and c != '>' and c != '|')
        {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
        if (out.items.len >= 200) break;
    }

    while (out.items.len > 0 and (out.items[0] == '.' or out.items[0] == ' ')) {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "upload");
    return out.toOwnedSlice(allocator);
}

/// True when `data` contains a line that would be interpreted as the boundary
/// delimiter by a receiving parser.
pub fn hasBoundaryCollision(data: []const u8, boundary: []const u8) bool {
    if (data.len == 0) return false;
    if (std.mem.startsWith(u8, data, "--") and std.mem.startsWith(u8, data[2..], boundary))
        return true;

    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, from, '\n')) |nl| {
        const line = data[nl + 1 ..];
        if (std.mem.startsWith(u8, line, "--") and
            std.mem.startsWith(u8, line[2..], boundary))
            return true;
        from = nl + 1;
    }
    return false;
}

test "header value validation rejects controls and DEL" {
    try std.testing.expect(isHeaderValueSafe("plain\tvalue"));
    try std.testing.expect(isHeaderValueSafe("obs-\x80-text"));
    try std.testing.expect(!isHeaderValueSafe("bad\x7fvalue"));
    try std.testing.expect(!isHeaderValueSafe("bad\x01value"));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidHeaderValue, writeHeaderValue(&out.writer, "bad\r\nvalue"));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "percent decoder rejects truncated escapes" {
    try std.testing.expectError(error.InvalidPercentEncoding, percentDecode(std.testing.allocator, "%"));
    try std.testing.expectError(error.InvalidPercentEncoding, percentDecode(std.testing.allocator, "%A"));

    const decoded = try percentDecode(std.testing.allocator, "a%20b");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a b", decoded);
}
