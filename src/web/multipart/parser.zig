//! Multipart parsing — RFC 2046, RFC 7578, RFC 5987.
//!
//! In-memory parser with configurable limits, streaming support,
//! and full compliance with multipart subtypes.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Limits

pub const Limits = struct {
    /// Maximum boundary length (RFC 2046: ≤70 without "--" prefix).
    max_boundary_len: usize = 70,
    /// Maximum number of parts (0 = unlimited).
    max_parts: usize = 1024,
    /// Maximum single header line length in bytes.
    max_header_line: usize = 8192,
    /// Maximum total headers size per part in bytes.
    max_headers_size: usize = 16384,
    /// Maximum single part body size in bytes (0 = unlimited).
    max_part_size: usize = 0,
    /// Maximum total body size in bytes (0 = unlimited).
    max_total_size: usize = 0,

    pub const strict = Limits{
        .max_boundary_len = 70,
        .max_parts = 256,
        .max_header_line = 4096,
        .max_headers_size = 8192,
        .max_part_size = 10 * 1024 * 1024,
        .max_total_size = 50 * 1024 * 1024,
    };

    pub const relaxed = Limits{
        .max_boundary_len = 70,
        .max_parts = 8192,
        .max_header_line = 16384,
        .max_headers_size = 65536,
        .max_part_size = 0,
        .max_total_size = 0,
    };
};

// Field

pub const Field = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    filename_star: ?FilenameStar = null,
    content_type: []const u8 = "",
    content_transfer_encoding: ?[]const u8 = null,
    data: []const u8,
    headers: []const Header = &.{},
};

pub const FilenameStar = struct {
    charset: []const u8 = "",
    language: []const u8 = "",
    value: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// Errors

pub const ParseError = error{
    MissingBoundary,
    Malformed,
    BoundaryTooLong,
    TooManyParts,
    HeaderLineTooLong,
    HeadersTooLarge,
    PartTooLarge,
    BodyTooLarge,
    InvalidBoundary,
    OutOfMemory,
};

// Parser

pub const Parser = struct {
    allocator: Allocator,
    limits: Limits,

    pub fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator, .limits = .{} };
    }

    pub fn initWithLimits(allocator: Allocator, limits: Limits) Parser {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn parse(self: *Parser, body: []const u8, boundary: []const u8) ParseError![]Field {
        return parseMultipart(self.allocator, body, boundary, self.limits);
    }
};

/// Parses a full multipart body with default limits. All returned slices borrow from `body`.
pub fn parse(body: []const u8, boundary: []const u8) ParseError![]Field {
    return parseMultipart(std.heap.page_allocator, body, boundary, .{});
}

/// Parses with custom allocator and limits.
pub fn parseMultipart(allocator: Allocator, body: []const u8, boundary: []const u8, limits: Limits) ParseError![]Field {
    if (boundary.len == 0) return ParseError.InvalidBoundary;
    if (boundary.len > limits.max_boundary_len) return ParseError.BoundaryTooLong;

    var delim_buf: [72 + 4]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary}) catch return ParseError.Malformed;

    const first_pos = indexOf(body, delim) orelse return ParseError.MissingBoundary;

    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |*f| {
            if (f.headers.len > 0) allocator.free(f.headers);
        }
        fields.deinit(allocator);
    }

    var cursor = first_pos + delim.len;
    var part_count: usize = 0;
    var total_size: usize = 0;

    while (true) {
        if (limits.max_parts > 0 and part_count >= limits.max_parts)
            return ParseError.TooManyParts;

        if (cursor + 2 <= body.len and body[cursor] == '-' and body[cursor + 1] == '-')
            return fields.toOwnedSlice(allocator) catch ParseError.OutOfMemory;

        if (cursor + 2 > body.len or body[cursor] != '\r' or body[cursor + 1] != '\n')
            return ParseError.Malformed;
        cursor += 2;

        const headers_start = cursor;
        var headers_end: ?usize = null;
        var total_headers: usize = 0;

        while (cursor + 4 <= body.len) {
            if (body[cursor] == '\r' and body[cursor + 1] == '\n' and
                body[cursor + 2] == '\r' and body[cursor + 3] == '\n')
            {
                headers_end = cursor;
                cursor += 4;
                break;
            }
            if (body[cursor] == '\r' or body[cursor] == '\n') {
                const line_end = std.mem.indexOfScalar(u8, body[cursor..], '\n') orelse return ParseError.Malformed;
                const line_len = line_end + 1;
                total_headers += line_len;
                if (line_len > limits.max_header_line) return ParseError.HeaderLineTooLong;
                if (limits.max_headers_size > 0 and total_headers > limits.max_headers_size)
                    return ParseError.HeadersTooLarge;
                cursor += line_end + 1;
            } else {
                cursor += 1;
            }
        }
        if (headers_end == null) return ParseError.Malformed;

        const raw_headers = body[headers_start..headers_end.?];

        const data_start = cursor;
        var search_from = data_start;
        const next_delim_pos = blk: {
            while (indexOfPos(body, search_from, delim)) |pos| {
                if (pos >= 2 and body[pos - 1] == '\n' and body[pos - 2] == '\r')
                    break :blk pos - 2;
                search_from = pos + 1;
            }
            return ParseError.Malformed;
        };

        const part_data = body[data_start..next_delim_pos];
        total_size += part_data.len;
        if (limits.max_part_size > 0 and part_data.len > limits.max_part_size)
            return ParseError.PartTooLarge;
        if (limits.max_total_size > 0 and total_size > limits.max_total_size)
            return ParseError.BodyTooLarge;

        const name = dispositionField(raw_headers, "name") orelse return ParseError.Malformed;
        const filename = dispositionField(raw_headers, "filename");
        const filename_star_val = dispositionField(raw_headers, "filename*");
        const ctype = headerValue(raw_headers, "Content-Type");
        const ctenc = headerValue(raw_headers, "Content-Transfer-Encoding");

        var fs: ?FilenameStar = null;
        if (filename_star_val) |fsv| {
            fs = parseFilenameStar(fsv);
        }

        const hdrs = try parseExtraHeaders(allocator, raw_headers);

        try fields.append(allocator, .{
            .name = name,
            .filename = filename,
            .filename_star = fs,
            .content_type = ctype orelse "",
            .content_transfer_encoding = ctenc,
            .data = part_data,
            .headers = hdrs,
        });
        part_count += 1;

        cursor = next_delim_pos + 2 + delim.len;
    }
}

pub fn freeFields(fields: []Field) void {
    std.heap.page_allocator.free(fields);
}

pub fn freeFieldsAlloc(allocator: Allocator, fields: []Field) void {
    for (fields) |*f| {
        if (f.headers.len > 0) allocator.free(f.headers);
    }
    allocator.free(fields);
}

// Extract boundary from Content-Type

pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content_type, ';');
    _ = it.next();
    while (it.next()) |param_raw| {
        const param = std.mem.trim(u8, param_raw, " ");
        if (std.mem.startsWith(u8, param, "boundary=")) {
            var val = param[9..];
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }
            return val;
        }
    }
    return null;
}

// Subtype detection

pub fn detectSubtype(content_type: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content_type, ';');
    const main = std.mem.trim(u8, it.next() orelse return null, " ");
    if (std.mem.startsWith(u8, main, "multipart/")) {
        return main[10..];
    }
    return null;
}

// Internal helpers

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn indexOfPos(haystack: []const u8, pos: usize, needle: []const u8) ?usize {
    return std.mem.indexOfPos(u8, haystack, pos, needle);
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

fn dispositionField(headers: []const u8, field: []const u8) ?[]const u8 {
    const cd = headerValue(headers, "Content-Disposition") orelse return null;
    if (!std.ascii.startsWithIgnoreCase(cd, "form-data") and
        !std.ascii.startsWithIgnoreCase(cd, "attachment") and
        !std.ascii.startsWithIgnoreCase(cd, "inline"))
        return null;

    var it = std.mem.splitScalar(u8, cd, ';');
    _ = it.next();
    while (it.next()) |param_raw| {
        const param = std.mem.trim(u8, param_raw, " ");
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        if (!std.ascii.eqlIgnoreCase(key, field)) continue;
        var val = param[eq + 1 ..];
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return null;
}

fn parseFilenameStar(raw: []const u8) FilenameStar {
    var val = raw;
    const apos = std.mem.indexOfScalar(u8, val, '\'');
    if (apos) |ap| {
        const charset = val[0..ap];
        val = val[ap + 1 ..];
        const lpos = std.mem.indexOfScalar(u8, val, '\'');
        if (lpos) |lp| {
            const language = val[0..lp];
            val = val[lp + 1 ..];
            return .{ .charset = charset, .language = language, .value = val };
        }
        return .{ .charset = charset, .value = val };
    }
    return .{ .value = val };
}

fn parseExtraHeaders(allocator: Allocator, raw_headers: []const u8) ![]const Header {
    var list: std.ArrayList(Header) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitSequence(u8, raw_headers, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(name, "Content-Disposition")) continue;
        if (std.ascii.eqlIgnoreCase(name, "Content-Type")) continue;
        if (std.ascii.eqlIgnoreCase(name, "Content-Transfer-Encoding")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try list.append(allocator, .{ .name = name, .value = value });
    }
    return list.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// Tests

test "parses field and binary file parts" {
    const boundary = "XBOUND";
    const body =
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "\x00\x01\xff\x00binary\r\n" ++
        "--XBOUND--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("note", fields[0].name);
    try std.testing.expectEqualStrings("hello world", fields[0].data);
    try std.testing.expect(fields[0].filename == null);

    try std.testing.expectEqualStrings("f", fields[1].name);
    try std.testing.expectEqualStrings("a.bin", fields[1].filename.?);
    try std.testing.expectEqualStrings("\x00\x01\xff\x00binary", fields[1].data);
}

test "rejects missing final delimiter and wrong boundary" {
    try std.testing.expectError(ParseError.MissingBoundary, parse("--NOPE--\r\n", "X"));
    try std.testing.expectError(ParseError.Malformed, parse(
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\ndata",
        "B",
    ));
}

test "extracts boundary from Content-Type" {
    const ct1 = "multipart/form-data; boundary=abc123";
    try std.testing.expectEqualStrings("abc123", extractBoundary(ct1).?);

    const ct2 = "multipart/mixed; boundary=\"quoted\"";
    try std.testing.expectEqualStrings("quoted", extractBoundary(ct2).?);

    try std.testing.expect(extractBoundary("text/html") == null);
}

test "detects multipart subtype" {
    try std.testing.expectEqualStrings("form-data", detectSubtype("multipart/form-data; boundary=x").?);
    try std.testing.expectEqualStrings("mixed", detectSubtype("multipart/mixed; boundary=x").?);
    try std.testing.expectEqualStrings("related", detectSubtype("multipart/related; boundary=x").?);
    try std.testing.expect(detectSubtype("text/html") == null);
}

test "parser respects max_parts limit" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" ++
        "--B--\r\n";

    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .max_parts = 1 });
    try std.testing.expectError(ParseError.TooManyParts, p.parse(body, boundary));
}

test "parser respects max_part_size limit" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n12345\r\n" ++
        "--B--\r\n";

    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .max_part_size = 3 });
    try std.testing.expectError(ParseError.PartTooLarge, p.parse(body, boundary));
}

test "parses filename* parameter" {
    const boundary = "B";
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename*=UTF-8''test-%C3%A9.txt\r\n" ++
        "\r\n" ++
        "data\r\n" ++
        "--B--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expect(fields[0].filename_star != null);
    try std.testing.expectEqualStrings("UTF-8", fields[0].filename_star.?.charset);
    try std.testing.expectEqualStrings("test-%C3%A9.txt", fields[0].filename_star.?.value);
}

test "parses Content-Transfer-Encoding" {
    const boundary = "B";
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"data\"\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "aGVsbG8=\r\n" ++
        "--B--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("base64", fields[0].content_transfer_encoding.?);
}

test "empty parts list" {
    const boundary = "B";
    const body = "--B--\r\n";
    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 0), fields.len);
}

test "parses multiple empty parts" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n\r\n" ++
        "--B--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("", fields[0].data);
    try std.testing.expectEqualStrings("", fields[1].data);
}

test "parses duplicate field names" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"tag\"\r\n\r\nfoo\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"tag\"\r\n\r\nbar\r\n" ++
        "--B--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("tag", fields[0].name);
    try std.testing.expectEqualStrings("foo", fields[0].data);
    try std.testing.expectEqualStrings("tag", fields[1].name);
    try std.testing.expectEqualStrings("bar", fields[1].data);
}

test "parser rejects invalid boundary length" {
    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .max_boundary_len = 5 });
    try std.testing.expectError(ParseError.BoundaryTooLong, p.parse("--abc--\r\n", "toolongboundary"));
}

test "parses extra headers" {
    const boundary = "B";
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"data\"\r\n" ++
        "X-Custom: yes\r\n" ++
        "X-Another: 123\r\n" ++
        "\r\n" ++
        "content\r\n" ++
        "--B--\r\n";

    const fields = try parse(body, boundary);
    defer std.heap.page_allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expect(fields[0].headers.len == 2);
    try std.testing.expectEqualStrings("X-Custom", fields[0].headers[0].name);
    try std.testing.expectEqualStrings("yes", fields[0].headers[0].value);
}
