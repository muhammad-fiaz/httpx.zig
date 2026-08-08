//! Multipart Form Data Parser and Builder for httpx.zig
//!
//! Implements RFC 2046 multipart/form-data for file uploads and form submissions.
//!
//! ## Usage
//! ```zig
//! // Build a multipart body
//! var builder = httpx.MultipartBuilder.init(allocator, "boundary123");
//! defer builder.deinit();
//! try builder.addField("name", "alice");
//! try builder.addFile("avatar", "photo.png", "image/png", png_bytes);
//! const body = try builder.build();
//! defer allocator.free(body);
//!
//! // Parse a multipart body
//! const boundary = httpx.extractMultipartBoundary(content_type).?;
//! var result = try httpx.parseMultipart(allocator, body, boundary);
//! defer result.deinit();
//! for (result.parts) |part| {
//!     std.debug.print("field={s} size={d}\n", .{ part.name, part.data.len });
//! }
//! ```
//!
//! ## Large File Uploads (Windows)
//!
//! On Windows the Winsock kernel send buffer is typically 8–64 KB. Sending a
//! single large multipart body (assembled entirely in memory) through one
//! `winsock.send()` call can cause the upload to hang or fail after a few
//! parts (see issue #26).  To avoid this:
//!
//! - Keep each part's `data` slice under `MAX_RECOMMENDED_CHUNK` (64 KB) when
//!   possible, or use `addFileChunked` which writes large blobs in small pieces.
//! - When doing multi-part chunked uploads, split the file at the call site
//!   (loop over 64 KB slices) and send each slice as a separate HTTP request.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Recommended maximum byte size for a single multipart file part's data.
///
/// Windows Winsock's kernel send buffer is typically 8–64 KB. Assembling a
/// multipart body larger than this limit and sending it as one request may
/// cause `winsock.send()` to block or return `WSAEWOULDBLOCK`, making the
/// upload appear to hang after a few parts (issue #26).
///
/// Use `MultipartBuilder.addFileChunked` or split large files at the call
/// site and issue one request per `MAX_RECOMMENDED_CHUNK`-sized slice.
pub const MAX_RECOMMENDED_CHUNK: usize = 65536;

/// A single parsed multipart part (field or file).
pub const Part = struct {
    /// Form field name from `Content-Disposition: form-data; name="..."`.
    name: []const u8,
    /// Original filename for file upload fields (`filename="..."`), or null.
    filename: ?[]const u8,
    /// Content-Type of this part (defaults to `"text/plain"`).
    content_type: []const u8,
    /// Raw bytes of the part body (slice into the parsed raw buffer).
    data: []const u8,
    /// All raw header pairs for this part.
    headers: []const [2][]const u8,
};

/// Parsed multipart result. Call `.deinit()` to release all memory.
pub const ParsedParts = struct {
    parts: []Part,
    _raw: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedParts) void {
        for (self.parts) |part| self.allocator.free(part.headers);
        self.allocator.free(self.parts);
        self.allocator.free(self._raw);
    }
};

/// Extracts the boundary value from a `Content-Type` header.
///
/// `"multipart fictional-data; boundary=abc123"` -> `"abc123"`
///
/// Returns null if no boundary is present.
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    const idx = std.ascii.findIgnoreCase(content_type, marker) orelse return null;
    var value = content_type[idx + marker.len ..];
    if (value.len > 0 and value[0] == '"') {
        value = value[1..];
        if (mem.indexOfScalar(u8, value, '"')) |end| return value[0..end];
    }
    if (mem.indexOfScalar(u8, value, ';')) |end| return mem.trim(u8, value[0..end], " \t");
    return mem.trim(u8, value, " \t\r\n");
}

/// Parses a complete multipart body into its constituent parts.
///
/// `boundary` is the raw boundary string (without the leading `--`).
/// Caller must call `result.deinit()` when done.
pub fn parse(allocator: Allocator, body: []const u8, boundary: []const u8) !ParsedParts {
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);

    const raw = try allocator.dupe(u8, body);
    errdefer allocator.free(raw);

    var parts_list = std.ArrayList(Part).empty;
    errdefer parts_list.deinit(allocator);

    var pos: usize = 0;
    while (pos < raw.len) {
        const delim_pos = mem.indexOf(u8, raw[pos..], delimiter) orelse break;
        pos += delim_pos + delimiter.len;

        // Final boundary ends with "--"
        if (pos + 2 <= raw.len and mem.eql(u8, raw[pos .. pos + 2], "--")) break;

        // Skip CRLF after delimiter
        if (pos + 2 <= raw.len and mem.eql(u8, raw[pos .. pos + 2], "\r\n")) {
            pos += 2;
        } else if (pos < raw.len and raw[pos] == '\n') {
            pos += 1;
        } else continue;

        // Find blank line that ends the part headers
        const headers_end_crlf = mem.indexOf(u8, raw[pos..], "\r\n\r\n");
        const headers_end_lf = mem.indexOf(u8, raw[pos..], "\n\n");
        const headers_end = if (headers_end_crlf) |c|
            if (headers_end_lf) |l| @min(c, l) else c
        else
            headers_end_lf orelse break;

        const headers_raw = raw[pos .. pos + headers_end];
        const sep_len: usize = if (headers_end_crlf != null and
            (headers_end_lf == null or headers_end_crlf.? <= headers_end_lf.?)) 4 else 2;
        const body_start = pos + headers_end + sep_len;

        // Find the next delimiter to know where this part's body ends
        const body_end_rel = mem.indexOf(u8, raw[body_start..], delimiter) orelse break;
        var body_end = body_start + body_end_rel;
        // Trim CRLF before the boundary
        if (body_end >= 2 and mem.eql(u8, raw[body_end - 2 .. body_end], "\r\n")) body_end -= 2 else if (body_end >= 1 and raw[body_end - 1] == '\n') body_end -= 1;

        // Parse headers for this part
        var name: []const u8 = "";
        var filename: ?[]const u8 = null;
        var content_type: []const u8 = "text/plain";
        var header_pairs = std.ArrayList([2][]const u8).empty;
        errdefer header_pairs.deinit(allocator);

        var header_lines = mem.splitAny(u8, headers_raw, "\n");
        while (header_lines.next()) |line| {
            const trimmed = mem.trim(u8, line, "\r\n \t");
            if (trimmed.len == 0) continue;
            const colon = mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const hname = mem.trim(u8, trimmed[0..colon], " \t");
            const hvalue = mem.trim(u8, trimmed[colon + 1 ..], " \t");
            try header_pairs.append(allocator, .{ hname, hvalue });

            if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
                if (extractParamValue(hvalue, "name")) |n| name = n;
                if (extractParamValue(hvalue, "filename")) |f| filename = f;
            } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
                content_type = hvalue;
            }
        }

        try parts_list.append(allocator, .{
            .name = name,
            .filename = filename,
            .content_type = content_type,
            .data = raw[body_start..body_end],
            .headers = try header_pairs.toOwnedSlice(allocator),
        });

        pos = body_start;
    }

    return .{
        .parts = try parts_list.toOwnedSlice(allocator),
        ._raw = raw,
        .allocator = allocator,
    };
}

fn extractParamValue(header_value: []const u8, param: []const u8) ?[]const u8 {
    var it = mem.splitAny(u8, header_value, ";");
    while (it.next()) |segment| {
        const s = mem.trim(u8, segment, " \t");
        const eq = mem.indexOfScalar(u8, s, '=') orelse continue;
        const key = mem.trim(u8, s[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, param)) continue;
        var val = mem.trim(u8, s[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        return val;
    }
    return null;
}

/// Escapes `"` characters in a string by replacing each with `\"`.
/// Caller owns the returned slice.
fn escapeQuote(allocator: Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        if (c == '"') count += 1;
    }
    if (count == 0) return input;
    var result = try allocator.alloc(u8, input.len + count);
    var i: usize = 0;
    for (input) |c| {
        if (c == '"') {
            result[i] = '\\';
            result[i + 1] = '"';
            i += 2;
        } else {
            result[i] = c;
            i += 1;
        }
    }
    return result;
}

/// Builds a multipart/form-data body incrementally.
pub const MultipartBuilder = struct {
    allocator: Allocator,
    boundary: []const u8,
    buf: std.ArrayList(u8),

    const Self = @This();

    /// Creates a builder with the given boundary string.
    ///
    /// `boundary` must not contain `--` and must not exceed 70 chars (RFC 2046).
    pub fn init(allocator: Allocator, boundary: []const u8) Self {
        return .{
            .allocator = allocator,
            .boundary = boundary,
            .buf = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit(self.allocator);
    }

    /// Appends a text field part.
    pub fn addField(self: *Self, name: []const u8, value: []const u8) !void {
        const escaped_name = try escapeQuote(self.allocator, name);
        defer if (escaped_name.ptr != name.ptr) self.allocator.free(escaped_name);
        try self.buf.print(self.allocator, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ self.boundary, escaped_name, value });
    }

    /// Appends a file upload part.
    pub fn addFile(
        self: *Self,
        name: []const u8,
        filename: []const u8,
        content_type: []const u8,
        data: []const u8,
    ) !void {
        const escaped_name = try escapeQuote(self.allocator, name);
        defer if (escaped_name.ptr != name.ptr) self.allocator.free(escaped_name);
        const escaped_filename = try escapeQuote(self.allocator, filename);
        defer if (escaped_filename.ptr != filename.ptr) self.allocator.free(escaped_filename);
        try self.buf.print(self.allocator, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{ self.boundary, escaped_name, escaped_filename, content_type });
        try self.buf.appendSlice(self.allocator, data);
        try self.buf.appendSlice(self.allocator, "\r\n");
    }

    /// Appends a file upload part, writing `data` in `MAX_RECOMMENDED_CHUNK`-sized
    /// slices to avoid allocating one giant buffer.
    ///
    /// Prefer this over `addFile` when `data.len` may exceed `MAX_RECOMMENDED_CHUNK`
    /// (64 KB). On Windows, assembling a single multipart body larger than the
    /// Winsock kernel send buffer (~8–64 KB) and sending it all at once can cause
    /// uploads to hang after a few parts (issue #26).
    pub fn addFileChunked(
        self: *Self,
        name: []const u8,
        filename: []const u8,
        content_type: []const u8,
        data: []const u8,
    ) !void {
        const escaped_name = try escapeQuote(self.allocator, name);
        defer if (escaped_name.ptr != name.ptr) self.allocator.free(escaped_name);
        const escaped_filename = try escapeQuote(self.allocator, filename);
        defer if (escaped_filename.ptr != filename.ptr) self.allocator.free(escaped_filename);
        try self.buf.print(self.allocator, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{ self.boundary, escaped_name, escaped_filename, content_type });
        var offset: usize = 0;
        while (offset < data.len) {
            const end = @min(offset + MAX_RECOMMENDED_CHUNK, data.len);
            try self.buf.appendSlice(self.allocator, data[offset..end]);
            offset = end;
        }
        try self.buf.appendSlice(self.allocator, "\r\n");
    }

    /// Finalizes and returns the complete body. Caller owns the result.
    pub fn build(self: *Self) ![]u8 {
        try self.buf.print(self.allocator, "--{s}--\r\n", .{self.boundary});
        return self.buf.toOwnedSlice(self.allocator);
    }

    /// Returns the `Content-Type` header value for this builder. Caller owns result.
    pub fn contentType(self: *const Self) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{self.boundary});
    }
};

// Tests

test "extractBoundary -- simple" {
    const b = extractBoundary("multipart/form-data; boundary=----Bound123");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("----Bound123", b.?);
}

test "extractBoundary -- quoted" {
    const b = extractBoundary("multipart/form-data; boundary=\"----Bound 456\"");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("----Bound 456", b.?);
}

test "extractBoundary -- missing" {
    try std.testing.expect(extractBoundary("text/plain") == null);
}

test "MultipartBuilder + parse roundtrip" {
    const allocator = std.testing.allocator;
    const boundary = "TestBound999";

    var b = MultipartBuilder.init(allocator, boundary);
    defer b.deinit();
    try b.addField("user", "alice");
    try b.addField("msg", "hello world");

    const body = try b.build();
    defer allocator.free(body);

    var r = try parse(allocator, body, boundary);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.parts.len);
    try std.testing.expectEqualStrings("user", r.parts[0].name);
    try std.testing.expectEqualStrings("alice", r.parts[0].data);
    try std.testing.expectEqualStrings("msg", r.parts[1].name);
    try std.testing.expectEqualStrings("hello world", r.parts[1].data);
}

test "MultipartBuilder file upload" {
    const allocator = std.testing.allocator;
    var b = MultipartBuilder.init(allocator, "FileBound");
    defer b.deinit();
    try b.addFile("upload", "test.txt", "text/plain", "file content here");

    const body = try b.build();
    defer allocator.free(body);

    var r = try parse(allocator, body, "FileBound");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.parts.len);
    try std.testing.expectEqualStrings("upload", r.parts[0].name);
    try std.testing.expectEqualStrings("test.txt", r.parts[0].filename.?);
    try std.testing.expectEqualStrings("text/plain", r.parts[0].content_type);
    try std.testing.expectEqualStrings("file content here", r.parts[0].data);
}

test "MultipartBuilder contentType" {
    const allocator = std.testing.allocator;
    var b = MultipartBuilder.init(allocator, "MyBound");
    defer b.deinit();
    const ct = try b.contentType();
    defer allocator.free(ct);
    try std.testing.expectEqualStrings("multipart/form-data; boundary=MyBound", ct);
}

test "MultipartBuilder addFileChunked + parse roundtrip" {
    const allocator = std.testing.allocator;
    const boundary = "ChunkedBound777";

    var b = MultipartBuilder.init(allocator, boundary);
    defer b.deinit();

    // Create a 150KB dummy file data to exceed MAX_RECOMMENDED_CHUNK (64KB)
    const large_data = try allocator.alloc(u8, 150 * 1024);
    defer allocator.free(large_data);
    @memset(large_data, 0x42); // 'B'

    try b.addFileChunked("big_file", "large.bin", "application/octet-stream", large_data);

    const body = try b.build();
    defer allocator.free(body);

    var r = try parse(allocator, body, boundary);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.parts.len);
    try std.testing.expectEqualStrings("big_file", r.parts[0].name);
    try std.testing.expectEqualStrings("large.bin", r.parts[0].filename.?);
    try std.testing.expectEqualStrings("application/octet-stream", r.parts[0].content_type);
    try std.testing.expectEqual(large_data.len, r.parts[0].data.len);
    try std.testing.expectEqualSlices(u8, large_data, r.parts[0].data);
}
