//! multipart/form-data encoding (RFC 7578).

const std = @import("std");

pub const Part = struct {
    name: []const u8,
    /// Null for plain form fields.
    filename: ?[]const u8 = null,
    content_type: []const u8 = "application/octet-stream",
    data: []const u8,
};

var boundary_counter = std.atomic.Value(u64).init(0);

/// Generates a 32-hex-char boundary unique within the process.
pub fn generateBoundary(buf: *[32]u8) []const u8 {
    // Boundaries need uniqueness, not secrecy: counter + address entropy.
    const n = boundary_counter.fetchAdd(1, .monotonic);
    var raw: [16]u8 = @splat(0);
    std.mem.writeInt(u64, raw[0..8], n, .little);
    std.mem.writeInt(u64, raw[8..16], @intFromPtr(buf) & std.math.maxInt(u64), .little);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 15];
    }
    return buf[0..];
}

pub const ContentTypeValue = struct {};

/// Builds the Content-Type header value including the boundary, e.g.
/// "multipart/form-data; boundary=<b>".
pub fn contentType(buf: []u8, boundary: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "multipart/form-data; boundary={s}", .{boundary}) catch "";
}

pub const EncodeError = error{
    WriteFailed,
    OutOfMemory,
};

fn writeHeader(w: anytype, part: Part) EncodeError!void {
    w.writeAll("Content-Disposition: form-data; name=\"") catch return EncodeError.WriteFailed;
    // Field names must not contain quotes per RFC 7578.
    if (std.mem.indexOfScalar(u8, part.name, '"') != null) return EncodeError.WriteFailed;
    w.writeAll(part.name) catch return EncodeError.WriteFailed;
    w.writeAll("\"") catch return EncodeError.WriteFailed;
    if (part.filename) |fname| {
        if (std.mem.indexOfScalar(u8, fname, '"') != null or std.mem.indexOfAny(u8, fname, "\r\n") != null)
            return EncodeError.WriteFailed;
        w.writeAll("; filename=\"") catch return EncodeError.WriteFailed;
        w.writeAll(fname) catch return EncodeError.WriteFailed;
        w.writeAll("\"") catch return EncodeError.WriteFailed;
    }
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    if (part.filename != null) {
        w.writeAll("Content-Type: ") catch return EncodeError.WriteFailed;
        w.writeAll(part.content_type) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }
}

/// Encodes all parts. Body is framed:
///   --B\r\n <headers>\r\n <data> \r\n--B\r\n ... \r\n--B--\r\n
pub fn encode(w: anytype, boundary: []const u8, parts: []const Part) EncodeError!void {
    for (parts) |part| {
        try writePartHeader(w, boundary, part);
        w.writeAll(part.data) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }
    try writeFinalBoundary(w, boundary);
}

/// Convenience: allocates and returns the complete encoded multipart payload as a single slice.
pub fn encodeAlloc(allocator: std.mem.Allocator, boundary: []const u8, parts: []const Part) EncodeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(&out.writer, boundary, parts);
    return out.toOwnedSlice() catch EncodeError.OutOfMemory;
}

/// Writes "--B\r\n" plus the part's headers. Streaming-safe.
pub fn writePartHeader(w: anytype, boundary: []const u8, part: Part) EncodeError!void {
    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    try writeHeader(w, part);
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
}

/// Writes the terminating "--B--\r\n". Streaming-safe.
pub fn writeFinalBoundary(w: anytype, boundary: []const u8) EncodeError!void {
    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("--\r\n") catch return EncodeError.WriteFailed;
}

/// Exact encoded length of one part header block ("--B\r\n" + headers + CRLF).
pub fn partHeaderLength(boundary: []const u8, part: Part) ?usize {
    var counting = CountingWriter{};
    writePartHeader(&counting, boundary, part) catch return null;
    return counting.total;
}

/// Counting sink for exact length math without buffering.
pub const CountingWriter = struct {
    total: usize = 0,

    pub const Error = error{NoSpaceLeft};

    pub fn writeAll(self: *CountingWriter, bytes: []const u8) Error!void {
        self.total += bytes.len;
    }

    pub fn writeByte(self: *CountingWriter, b: u8) Error!void {
        _ = b;
        self.total += 1;
    }
};

pub fn finalBoundaryLength(boundary: []const u8) usize {
    return boundary.len + 6; // "--" + boundary + "--" + "\r\n"
}

test "streaming length math matches buffered encode" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    const parts = [_]Part{
        .{ .name = "a", .data = "12345" },
        .{ .name = "f", .filename = "x.bin", .data = "0123456789" },
    };

    // Buffered reference.
    var ref: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ref.deinit();
    try encode(&ref.writer, b, &parts);
    const buffered_len = ref.written().len;

    // Incremental math.
    var total: usize = 0;
    for (parts) |p| {
        total += partHeaderLength(b, p).?;
        total += p.data.len + 2; // data + CRLF
    }
    total += finalBoundaryLength(b);

    try std.testing.expectEqual(buffered_len, total);
}

test "encodes field and file with canonical framing" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);
    try std.testing.expectEqual(@as(usize, 32), b.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{ .name = "field", .data = "v" },
        .{ .name = "file", .filename = "a.bin", .content_type = "application/x-foo", .data = &.{ 0, 1, 2 } },
    };
    try encode(&out.writer, b, &parts);

    const body = out.written();
    const needle_final = std.fmt.allocPrint(std.testing.allocator, "--{s}--\r\n", .{b}) catch unreachable;
    defer std.testing.allocator.free(needle_final);
    try std.testing.expect(std.mem.endsWith(u8, body, needle_final));
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"file\"; filename=\"a.bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: application/x-foo") != null);
}
