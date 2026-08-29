//! Multipart encoding — RFC 2046, RFC 7578, RFC 5987.
//!
//! Supports form-data, mixed, related, alternative, and custom subtypes.
//! Builder API with allocator at init boundary; streaming encode to any writer.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Subtypes

pub const Subtype = enum {
    form_data,
    mixed,
    related,
    alternative,

    pub fn label(self: Subtype) []const u8 {
        return switch (self) {
            .form_data => "form-data",
            .mixed => "mixed",
            .related => "related",
            .alternative => "alternative",
        };
    }
};

// Part

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    filename_star: ?FilenameStar = null,
    content_type: []const u8 = "application/octet-stream",
    content_transfer_encoding: ?[]const u8 = null,
    data: []const u8,
    headers: ?[]const Header = null,
};

pub const FilenameStar = struct {
    charset: []const u8 = "UTF-8",
    language: []const u8 = "",
    value: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// Builder

pub const Multipart = struct {
    allocator: Allocator,
    parts: std.ArrayList(Part),
    boundary_buf: [32]u8,
    boundary: []const u8,
    subtype: Subtype,

    pub fn init(allocator: Allocator) Multipart {
        return initWithSubtype(allocator, .form_data);
    }

    pub fn initWithSubtype(allocator: Allocator, subtype: Subtype) Multipart {
        var mb = Multipart{
            .allocator = allocator,
            .parts = .empty,
            .boundary_buf = undefined,
            .boundary = undefined,
            .subtype = subtype,
        };
        mb.boundary = generateBoundary(&mb.boundary_buf);
        return mb;
    }

    pub fn deinit(self: *Multipart) void {
        self.parts.deinit(self.allocator);
    }

    pub fn setBoundary(self: *Multipart, boundary: []const u8) void {
        self.boundary = boundary;
    }

    pub fn field(self: *Multipart, name: []const u8, value: []const u8) !void {
        try self.parts.append(self.allocator, .{
            .name = name,
            .data = value,
        });
    }

    pub fn file(self: *Multipart, name: []const u8, data: []const u8, opts: FileOptions) !void {
        try self.parts.append(self.allocator, .{
            .name = name,
            .filename = opts.filename,
            .filename_star = opts.filename_star,
            .content_type = opts.content_type orelse "application/octet-stream",
            .content_transfer_encoding = opts.content_transfer_encoding,
            .data = data,
            .headers = opts.headers,
        });
    }

    pub fn contentType(self: *const Multipart, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "multipart/{s}; boundary={s}", .{ self.subtype.label(), self.boundary }) catch "";
    }

    pub fn encode(self: *const Multipart, w: anytype) EncodeError!void {
        try encodeParts(w, self.boundary, self.parts.items);
    }

    pub fn encodeAlloc(self: *const Multipart) EncodeError![]u8 {
        return encodeAllocParts(self.allocator, self.boundary, self.parts.items);
    }

    pub fn boundaryLength(self: *const Multipart) []const u8 {
        return self.boundary;
    }
};

pub const FileOptions = struct {
    filename: ?[]const u8 = null,
    filename_star: ?FilenameStar = null,
    content_type: ?[]const u8 = null,
    content_transfer_encoding: ?[]const u8 = null,
    headers: ?[]const Header = null,
};

// Boundary

var boundary_counter = std.atomic.Value(u64).init(0);

pub fn generateBoundary(buf: *[32]u8) []const u8 {
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

// Content-Type

pub fn contentType(buf: []u8, boundary: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "multipart/form-data; boundary={s}", .{boundary}) catch "";
}

pub fn contentTypeSubtype(buf: []u8, subtype: Subtype, boundary: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "multipart/{s}; boundary={s}", .{ subtype.label(), boundary }) catch "";
}

// Errors

pub const EncodeError = error{
    WriteFailed,
    OutOfMemory,
};

// Encoding

fn writeHeader(w: anytype, part: Part) EncodeError!void {
    w.writeAll("Content-Disposition: form-data; name=\"") catch return EncodeError.WriteFailed;
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

    if (part.filename_star) |fs| {
        w.writeAll("; filename*=UTF-8''") catch return EncodeError.WriteFailed;
        w.writeAll(fs.value) catch return EncodeError.WriteFailed;
    }

    w.writeAll("\r\n") catch return EncodeError.WriteFailed;

    if (part.filename != null or part.content_type.len > 0) {
        w.writeAll("Content-Type: ") catch return EncodeError.WriteFailed;
        w.writeAll(part.content_type) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }

    if (part.content_transfer_encoding) |enc| {
        w.writeAll("Content-Transfer-Encoding: ") catch return EncodeError.WriteFailed;
        w.writeAll(enc) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }

    if (part.headers) |extra| {
        for (extra) |h| {
            w.writeAll(h.name) catch return EncodeError.WriteFailed;
            w.writeAll(": ") catch return EncodeError.WriteFailed;
            w.writeAll(h.value) catch return EncodeError.WriteFailed;
            w.writeAll("\r\n") catch return EncodeError.WriteFailed;
        }
    }
}

pub fn writePartHeader(w: anytype, boundary: []const u8, part: Part) EncodeError!void {
    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    try writeHeader(w, part);
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
}

pub fn writeFinalBoundary(w: anytype, boundary: []const u8) EncodeError!void {
    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("--\r\n") catch return EncodeError.WriteFailed;
}

pub fn encodeParts(w: anytype, boundary: []const u8, parts: []const Part) EncodeError!void {
    for (parts) |part| {
        try writePartHeader(w, boundary, part);
        w.writeAll(part.data) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }
    try writeFinalBoundary(w, boundary);
}

pub fn encodeAllocParts(allocator: Allocator, boundary: []const u8, parts: []const Part) EncodeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encodeParts(&out.writer, boundary, parts);
    return out.toOwnedSlice() catch EncodeError.OutOfMemory;
}

// Length math

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

pub fn partHeaderLength(boundary: []const u8, part: Part) ?usize {
    var counting = CountingWriter{};
    writePartHeader(&counting, boundary, part) catch return null;
    return counting.total;
}

pub fn finalBoundaryLength(boundary: []const u8) usize {
    return boundary.len + 6;
}

pub fn totalLength(boundary: []const u8, parts: []const Part) usize {
    var total: usize = 0;
    for (parts) |p| {
        total += partHeaderLength(boundary, p) orelse 0;
        total += p.data.len + 2;
    }
    total += finalBoundaryLength(boundary);
    return total;
}

// Tests

test "streaming length math matches buffered encode" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    const parts = [_]Part{
        .{ .name = "a", .data = "12345" },
        .{ .name = "f", .filename = "x.bin", .data = "0123456789" },
    };

    var ref: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ref.deinit();
    try encodeParts(&ref.writer, b, &parts);
    const buffered_len = ref.written().len;

    const computed = totalLength(b, &parts);
    try std.testing.expectEqual(buffered_len, computed);
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
    try encodeParts(&out.writer, b, &parts);

    const body = out.written();
    const needle_final = std.fmt.allocPrint(std.testing.allocator, "--{s}--\r\n", .{b}) catch unreachable;
    defer std.testing.allocator.free(needle_final);
    try std.testing.expect(std.mem.endsWith(u8, body, needle_final));
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"file\"; filename=\"a.bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: application/x-foo") != null);
}

test "builder API works" {
    var form = Multipart.init(std.testing.allocator);
    defer form.deinit();

    try form.field("name", "Alice");
    try form.file("avatar", "png-data", .{
        .filename = "avatar.png",
        .content_type = "image/png",
    });

    const body = try form.encodeAlloc();
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"avatar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"avatar.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: image/png") != null);
}

test "custom subtype works" {
    var form = Multipart.initWithSubtype(std.testing.allocator, .related);
    defer form.deinit();

    try form.file("data", "payload", .{ .content_type = "application/json" });

    var ct_buf: [128]u8 = undefined;
    const ct = form.contentType(&ct_buf);
    try std.testing.expect(std.mem.startsWith(u8, ct, "multipart/related;"));
}

test "filename* RFC 5987 encoding" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "file",
            .filename = "test.txt",
            .filename_star = .{ .value = "test-%C3%A9.txt" },
            .data = "content",
        },
    };
    try encodeParts(&out.writer, b, &parts);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "filename*=UTF-8''test-%C3%A9.txt") != null);
}

test "Content-Transfer-Encoding header" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "data",
            .content_transfer_encoding = "base64",
            .data = "aGVsbG8=",
        },
    };
    try encodeParts(&out.writer, b, &parts);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Transfer-Encoding: base64") != null);
}

test "extra headers in part" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "data",
            .headers = &.{.{ .name = "X-Custom", .value = "yes" }},
            .data = "content",
        },
    };
    try encodeParts(&out.writer, b, &parts);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "X-Custom: yes") != null);
}

test "boundary validation" {
    try std.testing.expect(validateBoundary("simple-boundary"));
    try std.testing.expect(validateBoundary("0123456789"));
    try std.testing.expect(!validateBoundary(""));
    try std.testing.expect(!validateBoundary("a" ++ "b" ** 70));
    try std.testing.expect(!validateBoundary("has space"));
    try std.testing.expect(!validateBoundary("has\x00null"));
}

test "empty parts list" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encodeParts(&out.writer, b, &.{});
    const body = out.written();
    var expected_buf: [40]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "--{s}--\r\n", .{b}) catch unreachable;
    try std.testing.expectEqualStrings(expected, body);
}
