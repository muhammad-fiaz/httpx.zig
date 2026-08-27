//! multipart/form-data parsing (server side of RFC 7578).
//!
//! In-memory parser: locates the boundary, splits parts, and extracts
//! Content-Disposition fields. Binary-safe; enforces the final delimiter.

const std = @import("std");

pub const Field = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: []const u8 = "",
    /// Raw part payload.
    data: []const u8,
};

pub const ParseError = error{
    MissingBoundary,
    Malformed,
};

fn findPart(needle: []const u8, hay: []const u8) ?usize {
    return std.mem.indexOf(u8, hay, needle);
}

/// Parses a full multipart body. All returned slices borrow from `body`.
pub fn parse(body: []const u8, boundary: []const u8) ParseError![]Field {
    var delim_buf: [70 + 4]u8 = undefined; // "--" + boundary(<=70)
    const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary}) catch return ParseError.Malformed;

    var first = findPart(delim, body) orelse return ParseError.MissingBoundary;

    // The first delimiter must start the body (after optional preamble).
    _ = &first;
    if (!std.mem.startsWith(u8, body[first..], delim)) return ParseError.MissingBoundary;

    var fields: std.ArrayList(Field) = .empty;

    var cursor = first + delim.len;
    while (true) {
        // Terminal delimiter?
        if (std.mem.startsWith(u8, body[cursor..], "--")) {
            // Optional trailing CRLF after "--".
            return fields.toOwnedSlice(std.heap.page_allocator) catch return ParseError.Malformed;
        }
        // Expect CRLF after delimiter, then headers until blank line.
        if (!std.mem.startsWith(u8, body[cursor..], "\r\n")) return ParseError.Malformed;
        cursor += 2;

        const head_end = std.mem.indexOfPos(u8, body, cursor, "\r\n\r\n") orelse
            return ParseError.Malformed;
        const headers = body[cursor..head_end];
        const data_start = head_end + 4;

        // Data runs until the next "\r\n--boundary".
        var search_from = data_start;
        const next_delim = blk: {
            while (std.mem.indexOfPos(u8, body, search_from, delim)) |pos| {
                if (pos >= 2 and body[pos - 1] == '\n' and body[pos - 2] == '\r')
                    break :blk pos - 2;
                search_from = pos + 1;
            }
            return ParseError.Malformed; // missing closing delimiter
        };

        const name = dispositionField(headers, "name") orelse return ParseError.Malformed;
        const filename = dispositionField(headers, "filename");
        const ctype = headerValue(headers, "Content-Type");

        fields.append(std.heap.page_allocator, .{
            .name = name,
            .filename = filename,
            .content_type = ctype orelse "",
            .data = body[data_start..next_delim],
        }) catch return ParseError.Malformed;

        cursor = next_delim + 2 + delim.len; // skip \r\n--boundary
    }
}

/// Frees the field list returned by `parse`.
pub fn freeFields(fields: []Field) void {
    std.heap.page_allocator.free(fields);
}

/// Case-insensitive single-header extraction within a part's raw headers.
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

/// Extracts a parameter from Content-Disposition ("name", "filename").
fn dispositionField(headers: []const u8, field: []const u8) ?[]const u8 {
    const cd = headerValue(headers, "Content-Disposition") orelse return null;
    if (!std.ascii.startsWithIgnoreCase(cd, "form-data")) return null;

    var it = std.mem.splitScalar(u8, cd, ';');
    _ = it.next(); // "form-data"
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
