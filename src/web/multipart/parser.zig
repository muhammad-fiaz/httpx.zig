//! Multipart parsing — RFC 2046, RFC 7578, RFC 5987.
//!
//! In-memory parser with configurable limits, streaming support,
//! and full compliance with multipart subtypes.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Limits

pub const Limits = struct {
    /// Maximum boundary length (RFC 2046: ≤70 without "--" prefix).
    maxBoundaryLen: usize = 70,
    /// Maximum number of parts (0 = unlimited).
    maxParts: usize = 1024,
    /// Maximum single header line length in bytes.
    maxHeaderLine: usize = 8192,
    /// Maximum total headers size per part in bytes.
    maxHeadersSize: usize = 16384,
    /// Maximum single part body size in bytes (0 = unlimited).
    maxPartSize: usize = 0,
    /// Maximum total body size in bytes (0 = unlimited).
    maxTotalSize: usize = 0,

    pub const strict = Limits{
        .maxBoundaryLen = 70,
        .maxParts = 256,
        .maxHeaderLine = 4096,
        .maxHeadersSize = 8192,
        .maxPartSize = 10 * 1024 * 1024,
        .maxTotalSize = 50 * 1024 * 1024,
    };

    pub const relaxed = Limits{
        .maxBoundaryLen = 70,
        .maxParts = 8192,
        .maxHeaderLine = 16384,
        .maxHeadersSize = 65536,
        .maxPartSize = 0,
        .maxTotalSize = 0,
    };
};

// Field

pub const Field = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    filenameStar: ?FilenameStar = null,
    contentType: []const u8 = "",
    contentTransferEncoding: ?[]const u8 = null,
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

pub const StreamEvent = union(enum) {
    partBegin: struct {
        name: []const u8,
        filename: ?[]const u8 = null,
        contentType: []const u8 = "",
    },
    partData: []const u8,
    partEnd,
    done,
};

pub const StreamParser = struct {
    allocator: Allocator,
    boundary: []const u8,
    delim_buf: [76]u8 = undefined,
    delim_len: usize = 0,
    limits: Limits,
    buffer: std.ArrayList(u8),
    state: State = .preamble,
    part_count: usize = 0,
    current_part_size: usize = 0,
    total_size: usize = 0,
    header_name_buf: [256]u8 = undefined,
    header_filename_buf: [256]u8 = undefined,
    header_ctype_buf: [128]u8 = undefined,

    const State = enum {
        preamble,
        headers,
        body,
        finished,
        closed,
    };

    pub fn init(allocator: Allocator, boundary: []const u8, limits: Limits) ParseError!StreamParser {
        if (boundary.len == 0) return ParseError.InvalidBoundary;
        if (boundary.len > limits.maxBoundaryLen) return ParseError.BoundaryTooLong;

        var sp = StreamParser{
            .allocator = allocator,
            .boundary = boundary,
            .limits = limits,
            .buffer = .empty,
        };
        const d = std.fmt.bufPrint(&sp.delim_buf, "--{s}", .{boundary}) catch return ParseError.Malformed;
        sp.delim_len = d.len;
        return sp;
    }

    pub fn deinit(self: *StreamParser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn getDelim(self: *const StreamParser) []const u8 {
        return self.delim_buf[0..self.delim_len];
    }

    fn dropFront(self: *StreamParser, count: usize) void {
        if (count == 0) return;
        const remaining = self.buffer.items.len - count;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[count..]);
        self.buffer.items.len = remaining;
    }

    pub fn feed(self: *StreamParser, chunk: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, chunk);
    }

    pub fn next(self: *StreamParser) !?StreamEvent {
        while (true) {
            switch (self.state) {
                .preamble => {
                    const delim = self.getDelim();
                    const pos = indexOf(self.buffer.items, delim) orelse {
                        if (self.buffer.items.len > delim.len) {
                            const drop = self.buffer.items.len - delim.len;
                            self.dropFront(drop);
                        }
                        return null;
                    };
                    const after_delim = pos + delim.len;
                    if (self.buffer.items.len < after_delim + 2) return null;

                    if (self.buffer.items[after_delim] == '-' and self.buffer.items[after_delim + 1] == '-') {
                        self.state = .finished;
                        self.buffer.clearRetainingCapacity();
                        return StreamEvent.done;
                    }
                    if (self.buffer.items[after_delim] == '\r' and self.buffer.items[after_delim + 1] == '\n') {
                        const drop_len = after_delim + 2;
                        self.dropFront(drop_len);
                        self.state = .headers;
                        continue;
                    }
                    return ParseError.Malformed;
                },
                .headers => {
                    var headers_end: ?usize = null;
                    if (self.buffer.items.len >= 4) {
                        var i: usize = 0;
                        while (i + 4 <= self.buffer.items.len) : (i += 1) {
                            if (self.buffer.items[i] == '\r' and self.buffer.items[i + 1] == '\n' and
                                self.buffer.items[i + 2] == '\r' and self.buffer.items[i + 3] == '\n')
                            {
                                headers_end = i;
                                break;
                            }
                        }
                    }
                    if (headers_end == null) {
                        if (self.limits.maxHeadersSize > 0 and self.buffer.items.len > self.limits.maxHeadersSize)
                            return ParseError.HeadersTooLarge;
                        return null;
                    }

                    const raw_headers = self.buffer.items[0..headers_end.?];
                    const name = dispositionField(raw_headers, "name") orelse return ParseError.Malformed;
                    const filename = dispositionField(raw_headers, "filename");
                    const ctype = headerValue(raw_headers, "Content-Type");

                    const name_len = @min(name.len, self.header_name_buf.len);
                    @memcpy(self.header_name_buf[0..name_len], name[0..name_len]);
                    const stable_name = self.header_name_buf[0..name_len];

                    var stable_filename: ?[]const u8 = null;
                    if (filename) |fn_val| {
                        const fn_len = @min(fn_val.len, self.header_filename_buf.len);
                        @memcpy(self.header_filename_buf[0..fn_len], fn_val[0..fn_len]);
                        stable_filename = self.header_filename_buf[0..fn_len];
                    }

                    var stable_ctype: []const u8 = "";
                    if (ctype) |ct_val| {
                        const ct_len = @min(ct_val.len, self.header_ctype_buf.len);
                        @memcpy(self.header_ctype_buf[0..ct_len], ct_val[0..ct_len]);
                        stable_ctype = self.header_ctype_buf[0..ct_len];
                    }

                    self.part_count += 1;
                    if (self.limits.maxParts > 0 and self.part_count > self.limits.maxParts)
                        return ParseError.TooManyParts;
                    self.current_part_size = 0;

                    const drop_len = headers_end.? + 4;
                    self.dropFront(drop_len);
                    self.state = .body;

                    return StreamEvent{
                        .partBegin = .{
                            .name = stable_name,
                            .filename = stable_filename,
                            .contentType = stable_ctype,
                        },
                    };
                },
                .body => {
                    var delim_search_buf: [80]u8 = undefined;
                    const body_delim = std.fmt.bufPrint(&delim_search_buf, "\r\n{s}", .{self.getDelim()}) catch return ParseError.Malformed;

                    if (indexOf(self.buffer.items, body_delim)) |pos| {
                        if (pos > 0) {
                            const data = self.buffer.items[0..pos];
                            self.current_part_size += data.len;
                            self.total_size += data.len;
                            if (self.limits.maxPartSize > 0 and self.current_part_size > self.limits.maxPartSize)
                                return ParseError.PartTooLarge;
                            if (self.limits.maxTotalSize > 0 and self.total_size > self.limits.maxTotalSize)
                                return ParseError.BodyTooLarge;

                            const out = try self.allocator.dupe(u8, data);
                            self.dropFront(pos);
                            return StreamEvent{ .partData = out };
                        }

                        const after = body_delim.len;
                        if (self.buffer.items.len < after + 2) return null;

                        if (self.buffer.items[after] == '-' and self.buffer.items[after + 1] == '-') {
                            self.state = .finished;
                            self.buffer.clearRetainingCapacity();
                            return StreamEvent.partEnd;
                        }
                        if (self.buffer.items[after] == '\r' and self.buffer.items[after + 1] == '\n') {
                            const drop_len = after + 2;
                            self.dropFront(drop_len);
                            self.state = .headers;
                            return StreamEvent.partEnd;
                        }
                        return ParseError.Malformed;
                    }

                    if (self.buffer.items.len > body_delim.len) {
                        const emit_len = self.buffer.items.len - body_delim.len;
                        const data = self.buffer.items[0..emit_len];
                        self.current_part_size += data.len;
                        self.total_size += data.len;
                        if (self.limits.maxPartSize > 0 and self.current_part_size > self.limits.maxPartSize)
                            return ParseError.PartTooLarge;
                        if (self.limits.maxTotalSize > 0 and self.total_size > self.limits.maxTotalSize)
                            return ParseError.BodyTooLarge;

                        const out = try self.allocator.dupe(u8, data);
                        self.dropFront(emit_len);
                        return StreamEvent{ .partData = out };
                    }

                    return null;
                },
                .finished => {
                    self.state = .closed;
                    return StreamEvent.done;
                },
                .closed => {
                    return null;
                },
            }
        }
    }
};

/// Parses a full multipart body with default limits. All returned slices borrow from `body`.
pub fn parse(body: []const u8, boundary: []const u8) ParseError![]Field {
    return parseMultipart(std.heap.page_allocator, body, boundary, .{});
}

/// Parses with custom allocator and limits.
pub fn parseMultipart(allocator: Allocator, body: []const u8, boundary: []const u8, limits: Limits) ParseError![]Field {
    if (boundary.len == 0) return ParseError.InvalidBoundary;
    if (boundary.len > limits.maxBoundaryLen) return ParseError.BoundaryTooLong;

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
        if (limits.maxParts > 0 and part_count >= limits.maxParts)
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
                if (line_len > limits.maxHeaderLine) return ParseError.HeaderLineTooLong;
                if (limits.maxHeadersSize > 0 and total_headers > limits.maxHeadersSize)
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

        const partData = body[data_start..next_delim_pos];
        total_size += partData.len;
        if (limits.maxPartSize > 0 and partData.len > limits.maxPartSize)
            return ParseError.PartTooLarge;
        if (limits.maxTotalSize > 0 and total_size > limits.maxTotalSize)
            return ParseError.BodyTooLarge;

        const name = dispositionField(raw_headers, "name") orelse return ParseError.Malformed;
        const filename = dispositionField(raw_headers, "filename");
        const filenameStar_val = dispositionField(raw_headers, "filename*");
        const ctype = headerValue(raw_headers, "Content-Type");
        const ctenc = headerValue(raw_headers, "Content-Transfer-Encoding");

        var fs: ?FilenameStar = null;
        if (filenameStar_val) |fsv| {
            fs = parseFilenameStar(fsv);
        }

        const hdrs = try parseExtraHeaders(allocator, raw_headers);

        try fields.append(allocator, .{
            .name = name,
            .filename = filename,
            .filenameStar = fs,
            .contentType = ctype orelse "",
            .contentTransferEncoding = ctenc,
            .data = partData,
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

pub fn extractBoundary(contentType: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, contentType, ';');
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

pub fn detectSubtype(contentType: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, contentType, ';');
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

test "parser respects maxParts limit" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" ++
        "--B--\r\n";

    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .maxParts = 1 });
    try std.testing.expectError(ParseError.TooManyParts, p.parse(body, boundary));
}

test "parser respects maxPartSize limit" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n12345\r\n" ++
        "--B--\r\n";

    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .maxPartSize = 3 });
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
    try std.testing.expect(fields[0].filenameStar != null);
    try std.testing.expectEqualStrings("UTF-8", fields[0].filenameStar.?.charset);
    try std.testing.expectEqualStrings("test-%C3%A9.txt", fields[0].filenameStar.?.value);
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
    try std.testing.expectEqualStrings("base64", fields[0].contentTransferEncoding.?);
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
    var p = Parser.initWithLimits(std.heap.page_allocator, .{ .maxBoundaryLen = 5 });
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

test "StreamParser processes multipart stream and emits events" {
    const a = std.testing.allocator;
    var sp = try StreamParser.init(a, "myboundary", .{});
    defer sp.deinit();

    const body =
        "--myboundary\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n\r\n" ++
        "value1\r\n" ++
        "--myboundary\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "file content line 1\nline 2\r\n" ++
        "--myboundary--\r\n";

    try sp.feed(body);

    var part1_name: ?[]u8 = null;
    defer if (part1_name) |p| a.free(p);
    var part1_data: std.ArrayList(u8) = .empty;
    defer part1_data.deinit(a);

    var part2_name: ?[]u8 = null;
    defer if (part2_name) |p| a.free(p);
    var part2_filename: ?[]u8 = null;
    defer if (part2_filename) |p| a.free(p);
    var part2_data: std.ArrayList(u8) = .empty;
    defer part2_data.deinit(a);

    var current_part: usize = 0;
    var completed_parts: usize = 0;

    while (try sp.next()) |ev| {
        switch (ev) {
            .partBegin => |pb| {
                current_part += 1;
                if (current_part == 1) {
                    part1_name = try a.dupe(u8, pb.name);
                } else if (current_part == 2) {
                    part2_name = try a.dupe(u8, pb.name);
                    if (pb.filename) |f| part2_filename = try a.dupe(u8, f);
                }
            },
            .partData => |pd| {
                defer a.free(pd);
                if (current_part == 1) {
                    try part1_data.appendSlice(a, pd);
                } else if (current_part == 2) {
                    try part2_data.appendSlice(a, pd);
                }
            },
            .partEnd => {
                completed_parts += 1;
            },
            .done => break,
        }
    }

    try std.testing.expectEqual(@as(usize, 2), completed_parts);
    try std.testing.expectEqualStrings("field1", part1_name.?);
    try std.testing.expectEqualStrings("value1", part1_data.items);
    try std.testing.expectEqualStrings("upload", part2_name.?);
    try std.testing.expectEqualStrings("test.txt", part2_filename.?);
    try std.testing.expectEqualStrings("file content line 1\nline 2", part2_data.items);
}

test "StreamParser incremental 1-byte feed test" {
    const a = std.testing.allocator;
    var sp = try StreamParser.init(a, "B", .{});
    defer sp.deinit();

    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"chunked\"\r\n\r\n" ++
        "incremental bytes stream\r\n" ++
        "--B--\r\n";

    var gathered: std.ArrayList(u8) = .empty;
    defer gathered.deinit(a);

    for (body) |byte| {
        const slice = [1]u8{byte};
        try sp.feed(&slice);
        while (try sp.next()) |ev| {
            switch (ev) {
                .partData => |pd| {
                    defer a.free(pd);
                    try gathered.appendSlice(a, pd);
                },
                .done => break,
                else => {},
            }
        }
    }

    while (try sp.next()) |ev| {
        switch (ev) {
            .partData => |pd| {
                defer a.free(pd);
                try gathered.appendSlice(a, pd);
            },
            .done => break,
            else => {},
        }
    }

    try std.testing.expectEqualStrings("incremental bytes stream", gathered.items);
}
