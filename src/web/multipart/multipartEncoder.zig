//! Multipart encoding — RFC 2046, RFC 7578, RFC 8187.
//!
//! Supports form-data, mixed, related, alternative, and custom subtypes.
//! Options-based API plus a bounded streaming encoder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mimeMod = @import("../../common/mime.zig");
const bodySourceMod = @import("../../common/bodySource.zig");
const common = @import("multipartCommon.zig");

// Subtypes

pub const Subtype = union(enum) {
    formData,
    mixed,
    related,
    alternative,
    byteranges,
    custom: []const u8,

    pub fn label(self: Subtype) []const u8 {
        return switch (self) {
            .formData => "form-data",
            .mixed => "mixed",
            .related => "related",
            .alternative => "alternative",
            .byteranges => "byteranges",
            .custom => |value| value,
        };
    }

    pub fn isValid(self: Subtype) bool {
        return switch (self) {
            .formData, .mixed, .related, .alternative, .byteranges => true,
            .custom => |value| common.isToken(value),
        };
    }
};

// Part

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    filenameStar: ?FilenameStar = null,
    dispositionType: []const u8 = "form-data",
    contentType: []const u8 = mimeMod.octetStream,
    contentTransferEncoding: ?[]const u8 = null,
    data: []const u8,
    headers: ?[]const Header = null,
};

pub const FilenameStar = struct {
    charset: []const u8 = "UTF-8",
    language: []const u8 = "",
    value: []const u8,
    /// Set to true when `value` is already RFC 8187 percent-encoded.
    encoded: bool = false,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const FileOptions = struct {
    filename: ?[]const u8 = null,
    filenameStar: ?FilenameStar = null,
    dispositionType: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    contentTransferEncoding: ?[]const u8 = null,
    headers: ?[]const Header = null,
};

pub const FieldValue = struct {
    name: []const u8,
    value: []const u8,
};

pub const File = struct {
    name: []const u8,
    data: []const u8,
    filename: ?[]const u8 = null,
    contentType: []const u8 = mimeMod.octetStream,
    headers: ?[]const Header = null,
};

pub const EncoderOptions = struct {
    subtype: Subtype = .formData,
    boundary: ?[]const u8 = null,
    /// Generic parts with full control. Either form works at the client:
    /// `.parts = .{ .{ .name = "meta", .data = json } }` (tuple) or a slice.
    parts: []const Part = &.{},
    fields: []const FieldValue = &.{},
    files: []const File = &.{},
};

fn toSubtype(value: anytype) Subtype {
    if (@TypeOf(value) == Subtype) return value;
    if (@TypeOf(value) == @TypeOf(null)) return .formData;
    if (@typeInfo(@TypeOf(value)) == .enum_literal) {
        const tag = @tagName(value);
        if (std.mem.eql(u8, tag, "mixed")) return .mixed;
        if (std.mem.eql(u8, tag, "related")) return .related;
        if (std.mem.eql(u8, tag, "alternative")) return .alternative;
        if (std.mem.eql(u8, tag, "byteranges")) return .byteranges;
        return .formData;
    }
    if (@hasField(@TypeOf(value), "custom")) return .{ .custom = value.custom };
    return .formData;
}

fn unwrapOptional(comptime T: type, value: T) ?[]const u8 {
    if (@typeInfo(T) == .optional) return value;
    return value;
}

fn partFrom(comptime P: type, p: P) Part {
    const filename: ?[]const u8 = if (@hasField(P, "filename")) unwrapOptional(@TypeOf(p.filename), p.filename) else null;
    const content_type: []const u8 = if (@hasField(P, "contentType")) blk: {
        const raw = unwrapOptional(@TypeOf(p.contentType), p.contentType);
        break :blk raw orelse if (filename) |f| mimeMod.fromPath(f) else mimeMod.octetStream;
    } else if (filename) |f| mimeMod.fromPath(f) else mimeMod.octetStream;
    return .{
        .name = if (@hasField(P, "name")) p.name else "",
        .filename = filename,
        .filenameStar = if (@hasField(P, "filenameStar")) p.filenameStar else null,
        .dispositionType = if (@hasField(P, "dispositionType")) p.dispositionType else "form-data",
        .contentType = content_type,
        .contentTransferEncoding = if (@hasField(P, "contentTransferEncoding")) p.contentTransferEncoding else null,
        .data = if (@hasField(P, "data")) p.data else if (@hasField(P, "value")) p.value else "",
        .headers = if (@hasField(P, "headers")) p.headers else null,
    };
}

fn fieldPartFrom(comptime F: type, field: F) Part {
    return .{
        .name = field.name,
        .data = if (@hasField(F, "value")) field.value else field.data,
        .contentType = mimeMod.textPlainUtf8,
    };
}

fn filePartFrom(comptime F: type, file: F) Part {
    return partFrom(F, file);
}

const ItemKind = enum { part, field, file };

/// Appends tuple or slice items, normalizing each to a `Part`. Tuples are
/// unrolled at compile time so `.parts = .{ ... }` and `&slice` both work.
fn appendItems(allocator: Allocator, list: *std.ArrayList(Part), items: anytype, comptime kind: ItemKind) EncodeError!void {
    const Info = @typeInfo(@TypeOf(items));
    if (Info == .@"struct" and Info.@"struct".is_tuple) {
        inline for (items) |item| {
            try list.append(allocator, switch (kind) {
                .part => partFrom(@TypeOf(item), item),
                .field => fieldPartFrom(@TypeOf(item), item),
                .file => filePartFrom(@TypeOf(item), item),
            });
        }
    } else {
        for (items) |item| {
            try list.append(allocator, switch (kind) {
                .part => partFrom(@TypeOf(item), item),
                .field => fieldPartFrom(@TypeOf(item), item),
                .file => filePartFrom(@TypeOf(item), item),
            });
        }
    }
}

/// Allocator and I/O backed multipart encoder. The allocator and `io` come
/// from the client/owner that created it, so callers never re-pass them.
/// Input parts may be slices or `.{}` tuples; the encoder owns the normalized
/// list until `deinit`.
pub const Encoder = struct {
    allocator: Allocator,
    io: std.Io,
    options: EncoderOptions,
    ownedParts: std.ArrayList(Part) = .empty,
    generatedBoundary: [32]u8 = undefined,
    hasGeneratedBoundary: bool = false,

    pub fn init(allocator: Allocator, io: std.Io, options: anytype) EncodeError!Encoder {
        const OptT = @TypeOf(options);
        if (@typeInfo(OptT) != .@"struct") @compileError("multipart encoder options must be a struct literal");

        var self = Encoder{ .allocator = allocator, .io = io, .options = .{} };
        errdefer self.ownedParts.deinit(allocator);

        if (@hasField(OptT, "subtype")) self.options.subtype = toSubtype(options.subtype);
        if (@hasField(OptT, "boundary")) self.options.boundary = unwrapOptional(@TypeOf(options.boundary), options.boundary);

        if (@hasField(OptT, "parts")) try appendItems(allocator, &self.ownedParts, options.parts, .part);
        if (@hasField(OptT, "fields")) try appendItems(allocator, &self.ownedParts, options.fields, .field);
        if (@hasField(OptT, "files")) {
            try appendItems(allocator, &self.ownedParts, options.files, .file);
        } else if (@hasField(OptT, "file")) {
            try self.ownedParts.append(allocator, filePartFrom(@TypeOf(options.file), options.file));
        } else if (@hasField(OptT, "name") and (@hasField(OptT, "data") or @hasField(OptT, "value"))) {
            // Direct single part: `.{ .name = "upload", .filename = "a.txt", .data = ... }`.
            try self.ownedParts.append(allocator, partFrom(OptT, options));
        }
        self.options.parts = self.ownedParts.items;

        if (!self.options.subtype.isValid()) return EncodeError.InvalidSubtype;
        if (self.options.boundary) |boundary_value| {
            if (!common.validateBoundary(boundary_value)) return EncodeError.InvalidBoundary;
        }
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        self.ownedParts.deinit(self.allocator);
    }

    pub fn boundary(self: *Encoder) []const u8 {
        if (self.options.boundary) |value| return value;
        if (self.hasGeneratedBoundary) return &self.generatedBoundary;
        self.hasGeneratedBoundary = true;
        return generateBoundary(&self.generatedBoundary);
    }

    pub fn contentType(self: *Encoder, buf: []u8) []const u8 {
        return contentTypeSubtype(buf, self.options.subtype, self.boundary());
    }

    pub fn encodeAlloc(self: *Encoder) EncodeError![]u8 {
        return encodeAllocParts(self.allocator, self.boundary(), self.options.parts);
    }
};

/// Constructs the high-level multipart encoder used by direct client options
/// and explicit streaming callers.
pub fn init(allocator: Allocator, io: std.Io, options: anytype) EncodeError!Encoder {
    return Encoder.init(allocator, io, options);
}

// Boundary

var boundaryCounter = std.atomic.Value(usize).init(0);

pub fn generateBoundary(buf: *[32]u8) []const u8 {
    const n: usize = boundaryCounter.fetchAdd(1, .monotonic);
    var raw: [16]u8 = @splat(0);
    std.mem.writeInt(usize, raw[0..@sizeOf(usize)], n, .little);
    std.mem.writeInt(usize, raw[@sizeOf(usize)..][0..@sizeOf(usize)], @intFromPtr(buf), .little);
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(buf[0..], &hex);
    return buf[0..];
}

/// Validates a boundary string per RFC 2046 Section 5.1.1.
pub fn validateBoundary(boundary: []const u8) bool {
    return common.validateBoundary(boundary);
}

// Content-Type

pub fn contentType(buf: []u8, boundary: []const u8) []const u8 {
    return contentTypeSubtype(buf, .formData, boundary);
}

pub fn contentTypeSubtype(buf: []u8, subtype: Subtype, boundary: []const u8) []const u8 {
    if (!subtype.isValid() or !common.validateBoundary(boundary)) return "";
    return std.fmt.bufPrint(buf, "multipart/{s}; boundary=\"{s}\"", .{ subtype.label(), boundary }) catch "";
}

// Errors

pub const EncodeError = error{
    WriteFailed,
    OutOfMemory,
    InvalidBoundary,
    InvalidSubtype,
    InvalidPartName,
    InvalidFilename,
    InvalidValue,
    InvalidHeader,
    InvalidContentType,
    InvalidContentTransferEncoding,
    DuplicateHeader,
    BoundaryCollision,
    Overflow,
    InvalidState,
};

// Encoding

fn writeHeader(w: anytype, part: Part) EncodeError!void {
    w.writeAll("Content-Disposition: ") catch return EncodeError.WriteFailed;
    w.writeAll(part.dispositionType) catch return EncodeError.WriteFailed;
    w.writeAll("; name=") catch return EncodeError.WriteFailed;
    common.writeQuoted(w, part.name) catch return EncodeError.WriteFailed;

    if (part.filename) |fname| {
        w.writeAll("; filename=") catch return EncodeError.WriteFailed;
        common.writeQuoted(w, fname) catch return EncodeError.WriteFailed;
    }

    if (part.filenameStar) |fs| {
        w.writeAll("; filename*=") catch return EncodeError.WriteFailed;
        w.writeAll(fs.charset) catch return EncodeError.WriteFailed;
        w.writeAll("'") catch return EncodeError.WriteFailed;
        w.writeAll(fs.language) catch return EncodeError.WriteFailed;
        w.writeAll("'") catch return EncodeError.WriteFailed;
        if (fs.encoded) {
            if (!common.isHeaderValueSafe(fs.value)) return EncodeError.InvalidFilename;
            w.writeAll(fs.value) catch return EncodeError.WriteFailed;
        } else {
            common.percentEncode(w, fs.value) catch return EncodeError.WriteFailed;
        }
    }

    w.writeAll("\r\n") catch return EncodeError.WriteFailed;

    if (part.filename != null or part.contentType.len > 0) {
        w.writeAll("Content-Type: ") catch return EncodeError.WriteFailed;
        w.writeAll(part.contentType) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }

    if (part.contentTransferEncoding) |enc| {
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

fn validatePart(part: Part) EncodeError!void {
    if (!common.isToken(part.dispositionType)) return EncodeError.InvalidHeader;
    if (part.name.len == 0 or !common.isQuotedStringSafe(part.name))
        return EncodeError.InvalidPartName;
    if (part.filename) |fname| {
        if (!common.isQuotedStringSafe(fname)) return EncodeError.InvalidFilename;
    }
    if (part.filenameStar) |fs| {
        if (!common.isToken(fs.charset)) return EncodeError.InvalidFilename;
        if (fs.language.len > 0 and !common.isToken(fs.language)) return EncodeError.InvalidFilename;
        if (!common.isHeaderValueSafe(fs.value)) return EncodeError.InvalidFilename;
    }
    if (part.contentType.len > 0 and !common.isHeaderValueSafe(part.contentType))
        return EncodeError.InvalidContentType;
    if (part.contentTransferEncoding) |enc| {
        if (!common.isToken(enc)) return EncodeError.InvalidContentTransferEncoding;
    }
    if (part.headers) |headers| {
        for (headers) |h| {
            if (!common.isToken(h.name) or !common.isHeaderValueSafe(h.value))
                return EncodeError.InvalidHeader;
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Disposition") or
                std.ascii.eqlIgnoreCase(h.name, "Content-Type") or
                std.ascii.eqlIgnoreCase(h.name, "Content-Transfer-Encoding"))
                return EncodeError.DuplicateHeader;
        }
    }
}

pub fn writePartHeader(w: anytype, boundary: []const u8, part: Part) EncodeError!void {
    if (!common.validateBoundary(boundary)) return EncodeError.InvalidBoundary;
    try validatePart(part);
    if (common.hasBoundaryCollision(part.data, boundary)) return EncodeError.BoundaryCollision;

    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    try writeHeader(w, part);
    w.writeAll("\r\n") catch return EncodeError.WriteFailed;
}

pub fn writeFinalBoundary(w: anytype, boundary: []const u8) EncodeError!void {
    if (!common.validateBoundary(boundary)) return EncodeError.InvalidBoundary;
    w.writeAll("--") catch return EncodeError.WriteFailed;
    w.writeAll(boundary) catch return EncodeError.WriteFailed;
    w.writeAll("--\r\n") catch return EncodeError.WriteFailed;
}

fn encodeParts(w: anytype, boundary: []const u8, parts: []const Part) EncodeError!void {
    if (!common.validateBoundary(boundary)) return EncodeError.InvalidBoundary;
    for (parts) |part| {
        try validatePart(part);
        if (common.hasBoundaryCollision(part.data, boundary)) return EncodeError.BoundaryCollision;
    }
    for (parts) |part| {
        try writePartHeader(w, boundary, part);
        w.writeAll(part.data) catch return EncodeError.WriteFailed;
        w.writeAll("\r\n") catch return EncodeError.WriteFailed;
    }
    try writeFinalBoundary(w, boundary);
}

fn encodeAllocParts(allocator: Allocator, boundary: []const u8, parts: []const Part) EncodeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encodeParts(&out.writer, boundary, parts);
    return out.toOwnedSlice() catch EncodeError.OutOfMemory;
}

/// Pull-based multipart body producer for streaming request uploads.
///
/// Only the part headers, CRLF separators, and final boundary are copied into
/// an owned `meta` buffer; payload bytes are referenced in place by the part
/// slices. Memory use is therefore bounded by header size regardless of body
/// size, and the source is replayable when the caller keeps the part slices
/// alive. Calling `deinit` releases the header buffer.
pub const StreamingBody = struct {
    allocator: Allocator,
    meta: []u8,
    ops: []Op,
    total: u64,
    op_index: usize = 0,
    op_offset: usize = 0,

    const Op = union(enum) {
        meta: struct { off: usize, len: usize },
        data: []const u8,
    };

    pub fn init(allocator: Allocator, boundary: []const u8, parts: []const Part) EncodeError!StreamingBody {
        if (!common.validateBoundary(boundary)) return EncodeError.InvalidBoundary;

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var ops: std.ArrayList(Op) = .empty;
        errdefer ops.deinit(allocator);

        for (parts) |part| {
            const header_off = out.writer.end;
            try writePartHeader(&out.writer, boundary, part);
            const header_len = out.writer.end - header_off;
            ops.append(allocator, .{ .meta = .{ .off = header_off, .len = header_len } }) catch return EncodeError.OutOfMemory;
            ops.append(allocator, .{ .data = part.data }) catch return EncodeError.OutOfMemory;
            const crlf_off = out.writer.end;
            out.writer.writeAll("\r\n") catch return EncodeError.WriteFailed;
            ops.append(allocator, .{ .meta = .{ .off = crlf_off, .len = 2 } }) catch return EncodeError.OutOfMemory;
        }

        const final_off = out.writer.end;
        writeFinalBoundary(&out.writer, boundary) catch |err| switch (err) {
            EncodeError.WriteFailed => return EncodeError.WriteFailed,
            else => return err,
        };
        const final_len = out.writer.end - final_off;
        ops.append(allocator, .{ .meta = .{ .off = final_off, .len = final_len } }) catch return EncodeError.OutOfMemory;

        const meta = out.toOwnedSlice() catch return EncodeError.OutOfMemory;
        errdefer allocator.free(meta);
        const owned_ops = ops.toOwnedSlice(allocator) catch return EncodeError.OutOfMemory;

        var total: u64 = @intCast(meta.len);
        for (parts) |part| total += @intCast(part.data.len);
        return .{ .allocator = allocator, .meta = meta, .ops = owned_ops, .total = total };
    }

    pub fn deinit(self: *StreamingBody) void {
        self.allocator.free(self.meta);
        self.allocator.free(self.ops);
        self.* = undefined;
    }

    pub fn contentLength(self: *const StreamingBody) u64 {
        return self.total;
    }

    pub fn reset(self: *StreamingBody) void {
        self.op_index = 0;
        self.op_offset = 0;
    }

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *StreamingBody = @ptrCast(@alignCast(ctx));
        var written: usize = 0;
        while (written < buf.len and self.op_index < self.ops.len) {
            switch (self.ops[self.op_index]) {
                .meta => |m| {
                    const remaining = m.len - self.op_offset;
                    const n = @min(remaining, buf.len - written);
                    @memcpy(buf[written .. written + n], self.meta[m.off + self.op_offset ..][0..n]);
                    written += n;
                    self.op_offset += n;
                    if (self.op_offset == m.len) {
                        self.op_index += 1;
                        self.op_offset = 0;
                    }
                },
                .data => |data| {
                    const remaining = data.len - self.op_offset;
                    const n = @min(remaining, buf.len - written);
                    @memcpy(buf[written .. written + n], data[self.op_offset..][0..n]);
                    written += n;
                    self.op_offset += n;
                    if (self.op_offset == data.len) {
                        self.op_index += 1;
                        self.op_offset = 0;
                    }
                },
            }
        }
        return written;
    }

    fn resetCb(ctx: *anyopaque) anyerror!void {
        const self: *StreamingBody = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    pub fn source(self: *StreamingBody) bodySourceMod.BodySource {
        return .{
            .ptr = self,
            .readFn = read,
            .contentLength = self.total,
            .resetFn = resetCb,
            .closeFn = null,
        };
    }
};

// Streaming encoder. Callers obtain it with `encoder.stream(writer, .{})`
// and use the inferred value without naming an implementation type.

const StreamEncoder = struct {
    writer: *std.Io.Writer,
    boundary: []const u8,
    subtype: Subtype,
    state: State = .idle,
    length: usize = 0,
    tail: [72]u8 = undefined,
    tailLen: usize = 0,

    const State = enum { idle, part, finished };

    pub fn init(writer: *std.Io.Writer, subtype: Subtype, boundary: []const u8) EncodeError!StreamEncoder {
        if (!subtype.isValid()) return EncodeError.InvalidSubtype;
        if (!common.validateBoundary(boundary)) return EncodeError.InvalidBoundary;
        return .{ .writer = writer, .boundary = boundary, .subtype = subtype };
    }

    pub fn beginPart(self: *StreamEncoder, name: []const u8, opts: FileOptions) EncodeError!void {
        if (self.state == .part) return EncodeError.InvalidState;
        if (self.state == .finished) return EncodeError.InvalidState;

        const part = Part{
            .name = name,
            .filename = opts.filename,
            .filenameStar = opts.filenameStar,
            .dispositionType = opts.dispositionType orelse "form-data",
            .contentType = opts.contentType orelse mimeMod.octetStream,
            .contentTransferEncoding = opts.contentTransferEncoding,
            .headers = opts.headers,
            .data = "",
        };
        const header_len = try partHeaderLength(self.boundary, part);
        try writePartHeader(self.writer, self.boundary, part);
        self.length = try addUsize(self.length, header_len);
        self.tailLen = 2;
        self.tail[0] = '\r';
        self.tail[1] = '\n';
        self.state = .part;
    }

    pub fn write(self: *StreamEncoder, data: []const u8) EncodeError!void {
        if (self.state != .part) return EncodeError.InvalidState;
        if (data.len == 0) return;

        var patternBuf: [74]u8 = undefined;
        const pattern = std.fmt.bufPrint(&patternBuf, "\n--{s}", .{self.boundary}) catch
            return EncodeError.InvalidBoundary;
        if (self.streamCollision(data, pattern)) return EncodeError.BoundaryCollision;

        self.writer.writeAll(data) catch return EncodeError.WriteFailed;
        self.length = try addUsize(self.length, data.len);
        self.updateTail(data, pattern.len - 1);
    }

    pub fn endPart(self: *StreamEncoder) EncodeError!void {
        if (self.state != .part) return EncodeError.InvalidState;
        self.writer.writeAll("\r\n") catch return EncodeError.WriteFailed;
        self.length = try addUsize(self.length, 2);
        self.state = .idle;
    }

    pub fn finish(self: *StreamEncoder) EncodeError!void {
        if (self.state == .finished) return;
        if (self.state == .part) return EncodeError.InvalidState;
        try writeFinalBoundary(self.writer, self.boundary);
        self.length = try addUsize(self.length, finalBoundaryLength(self.boundary));
        self.state = .finished;
    }

    pub fn contentLength(self: *const StreamEncoder) usize {
        return self.length;
    }

    fn streamCollision(self: *const StreamEncoder, data: []const u8, pattern: []const u8) bool {
        if (std.mem.indexOf(u8, data, pattern) != null) return true;
        if (std.mem.startsWith(u8, data, "--") and
            std.mem.startsWith(u8, data[2..], self.boundary)) return true;

        const keep = pattern.len - 1;
        const tail_len = @min(self.tailLen, keep);
        const data_len = @min(data.len, keep);
        var scan: [148]u8 = undefined;
        @memcpy(scan[0..tail_len], self.tail[self.tailLen - tail_len .. self.tailLen]);
        @memcpy(scan[tail_len .. tail_len + data_len], data[0..data_len]);
        return std.mem.indexOf(u8, scan[0 .. tail_len + data_len], pattern) != null;
    }

    fn updateTail(self: *StreamEncoder, data: []const u8, keep: usize) void {
        if (data.len >= keep) {
            @memcpy(self.tail[0..keep], data[data.len - keep ..]);
            self.tailLen = keep;
            return;
        }

        const available = @min(self.tailLen + data.len, keep);
        var combined: [148]u8 = undefined;
        @memcpy(combined[0..self.tailLen], self.tail[0..self.tailLen]);
        @memcpy(combined[self.tailLen .. self.tailLen + data.len], data);
        @memcpy(self.tail[0..available], combined[self.tailLen + data.len - available .. self.tailLen + data.len]);
        self.tailLen = available;
    }
};

pub const StreamOptions = struct {
    subtype: Subtype = .formData,
    boundary: []const u8,
};

/// Creates a bounded-memory writer for incremental multipart output.
/// The writer owns I/O; the returned encoder borrows it until `finish`.
pub fn stream(writer: *std.Io.Writer, options: StreamOptions) EncodeError!StreamEncoder {
    return StreamEncoder.init(writer, options.subtype, options.boundary);
}

// Length math

pub const CountingWriter = struct {
    total: usize = 0,

    pub const Error = error{Overflow};

    pub fn writeAll(self: *CountingWriter, bytes: []const u8) Error!void {
        self.total = std.math.add(usize, self.total, bytes.len) catch return Error.Overflow;
    }

    pub fn writeByte(self: *CountingWriter, b: u8) Error!void {
        _ = b;
        self.total = std.math.add(usize, self.total, 1) catch return Error.Overflow;
    }
};

fn addUsize(a: usize, b: usize) EncodeError!usize {
    return std.math.add(usize, a, b) catch EncodeError.Overflow;
}

pub fn partHeaderLength(boundary: []const u8, part: Part) EncodeError!usize {
    var counting = CountingWriter{};
    writePartHeader(&counting, boundary, part) catch |err| switch (err) {
        EncodeError.WriteFailed => return EncodeError.Overflow,
        else => return err,
    };
    return counting.total;
}

pub fn finalBoundaryLength(boundary: []const u8) usize {
    return boundary.len + 6;
}

pub fn totalLength(boundary: []const u8, parts: []const Part) EncodeError!usize {
    var total: usize = 0;
    for (parts) |p| {
        total = try addUsize(total, try partHeaderLength(boundary, p));
        total = try addUsize(total, p.data.len);
        total = try addUsize(total, 2);
    }
    total = try addUsize(total, finalBoundaryLength(boundary));
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
    const bufferedLen = ref.written().len;

    const computed = try totalLength(b, &parts);
    try std.testing.expectEqual(bufferedLen, computed);
}

test "encodes field and file with canonical framing" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);
    try std.testing.expectEqual(@as(usize, 32), b.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{ .name = "field", .data = "v" },
        .{ .name = "file", .filename = "a.bin", .contentType = "application/x-foo", .data = &.{ 0, 1, 2 } },
    };
    try encodeParts(&out.writer, b, &parts);

    const body = out.written();
    const needleFinal = std.fmt.allocPrint(std.testing.allocator, "--{s}--\r\n", .{b}) catch unreachable;
    defer std.testing.allocator.free(needleFinal);
    try std.testing.expect(std.mem.endsWith(u8, body, needleFinal));
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"file\"; filename=\"a.bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: application/x-foo") != null);
}

test "encoder API encodes fields and files" {
    const fields = [_]FieldValue{.{ .name = "name", .value = "Alice" }};
    const files = [_]File{.{
        .name = "avatar",
        .data = "png-data",
        .filename = "avatar.png",
        .contentType = "image/png",
    }};
    var encoder = try init(std.testing.allocator, std.testing.io, .{ .fields = &fields, .files = &files });
    defer encoder.deinit();

    const body = try encoder.encodeAlloc();
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"avatar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"avatar.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: image/png") != null);
}

test "custom subtype works" {
    const files = [_]File{.{ .name = "data", .data = "payload", .contentType = "application/json" }};
    var encoder = try init(std.testing.allocator, std.testing.io, .{ .subtype = .related, .files = &files });
    defer encoder.deinit();

    var ctBuf: [128]u8 = undefined;
    const ct = encoder.contentType(&ctBuf);
    try std.testing.expect(std.mem.startsWith(u8, ct, "multipart/related;"));
    try std.testing.expect(std.mem.indexOf(u8, ct, "boundary=\"") != null);
}

test "custom subtype is emitted as a validated token" {
    var encoder = try init(std.testing.allocator, std.testing.io, .{ .subtype = .{ .custom = "signed" } });
    defer encoder.deinit();
    var ct_buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, encoder.contentType(&ct_buf), "multipart/signed;"));

    try std.testing.expectError(EncodeError.InvalidSubtype, init(std.testing.allocator, std.testing.io, .{
        .subtype = .{ .custom = "signed\r\nX-Injected: yes" },
    }));
}

test "filename* RFC 8187 encoding is applied to raw UTF-8" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "file",
            .filename = "test.txt",
            .filenameStar = .{ .value = "test-é.txt" },
            .data = "content",
        },
    };
    try encodeParts(&out.writer, b, &parts);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "filename*=UTF-8''test-%C3%A9.txt") != null);
}

test "filename* accepts pre-encoded value" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "file",
            .filenameStar = .{ .value = "test-%C3%A9.txt", .encoded = true },
            .data = "x",
        },
    };
    try encodeParts(&out.writer, b, &parts);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "filename*=UTF-8''test-%C3%A9.txt") != null);
}

test "Content-Transfer-Encoding header" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{
            .name = "data",
            .contentTransferEncoding = "base64",
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
    const tooLong: [71]u8 = comptime blk: {
        var out: [71]u8 = @splat('b');
        out[0] = 'a';
        break :blk out;
    };
    try std.testing.expect(!validateBoundary(&tooLong));
    try std.testing.expect(!validateBoundary("has space"));
    try std.testing.expect(!validateBoundary("has\x00null"));
}

test "generated boundary is lowercase hex and unique" {
    var firstBuf: [32]u8 = undefined;
    var secondBuf: [32]u8 = undefined;
    const first = generateBoundary(&firstBuf);
    const second = generateBoundary(&secondBuf);
    try std.testing.expectEqual(@as(usize, 32), first.len);
    for (first) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(validateBoundary(first));
}

test "empty parts list" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encodeParts(&out.writer, b, &.{});
    const body = out.written();
    var expectedBuf: [40]u8 = undefined;
    const expected = std.fmt.bufPrint(&expectedBuf, "--{s}--\r\n", .{b}) catch unreachable;
    try std.testing.expectEqualStrings(expected, body);
}

test "encoder rejects CRLF injection in names and headers" {
    {
        const fields = [_]FieldValue{.{ .name = "a\r\nX-Evil: 1", .value = "v" }};
        var encoder = try init(std.testing.allocator, std.testing.io, .{ .fields = &fields });
        defer encoder.deinit();
        try std.testing.expectError(EncodeError.InvalidPartName, encoder.encodeAlloc());
    }
    {
        const files = [_]File{.{ .name = "f", .data = "v", .filename = "a\r\nX-Evil: 1" }};
        var encoder = try init(std.testing.allocator, std.testing.io, .{ .files = &files });
        defer encoder.deinit();
        try std.testing.expectError(EncodeError.InvalidFilename, encoder.encodeAlloc());
    }
    {
        const headers = [_]Header{.{ .name = "X-Test", .value = "v\r\nX-Evil: 1" }};
        const files = [_]File{.{ .name = "f", .data = "v", .headers = &headers }};
        var encoder = try init(std.testing.allocator, std.testing.io, .{ .files = &files });
        defer encoder.deinit();
        try std.testing.expectError(EncodeError.InvalidHeader, encoder.encodeAlloc());
    }
}

test "encoder quotes name and filename values" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{
        .{ .name = "a\"b\\c", .filename = "f\"g.txt", .data = "x" },
    };
    try encodeParts(&out.writer, b, &parts);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "name=\"a\\\"b\\\\c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "filename=\"f\\\"g.txt\"") != null);
}

test "encoder detects boundary collisions before writing" {
    var bbuf: [32]u8 = undefined;
    const b = generateBoundary(&bbuf);
    const body = std.fmt.allocPrint(std.testing.allocator, "safe\r\n--{s}\r\nmore", .{b}) catch unreachable;
    defer std.testing.allocator.free(body);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const parts = [_]Part{.{ .name = "x", .data = body }};
    try std.testing.expectError(EncodeError.BoundaryCollision, encodeParts(&out.writer, b, &parts));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "stream encoder emits same bytes as buffered encoder" {
    const boundary = "stream-boundary";
    var stream_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream_buf.deinit();

    var enc = try StreamEncoder.init(&stream_buf.writer, .formData, boundary);
    try enc.beginPart("a", .{});
    try enc.write("hello");
    try enc.endPart();
    try enc.beginPart("f", .{ .filename = "x.bin", .contentType = "application/octet-stream" });
    try enc.write(&.{ 0, 1, 2 });
    try enc.endPart();
    try enc.finish();

    const parts = [_]Part{
        .{ .name = "a", .data = "hello" },
        .{ .name = "f", .filename = "x.bin", .contentType = "application/octet-stream", .data = &.{ 0, 1, 2 } },
    };
    var ref: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ref.deinit();
    try encodeParts(&ref.writer, boundary, &parts);

    try std.testing.expectEqualStrings(ref.written(), stream_buf.written());
    try std.testing.expectEqual(ref.written().len, enc.contentLength());
}

test "stream encoder detects split boundary collision" {
    const boundary = "split-boundary";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var enc = try StreamEncoder.init(&out.writer, .formData, boundary);
    try enc.beginPart("x", .{});
    try enc.write("abc\r");
    try std.testing.expectError(EncodeError.BoundaryCollision, enc.write("\n--" ++ boundary));
}

test "streaming body source matches buffered encoder byte-for-byte" {
    const boundary = "streaming-body-boundary";
    const parts = [_]Part{
        .{ .name = "field", .data = "hello", .contentType = mimeMod.textPlainUtf8 },
        .{ .name = "file", .filename = "data.bin", .data = &.{ 0, 1, 2, 3, 0xFF } },
        .{ .name = "empty", .data = "" },
    };

    var reference: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reference.deinit();
    try encodeParts(&reference.writer, boundary, &parts);

    var body = try StreamingBody.init(std.testing.allocator, boundary, &parts);
    defer body.deinit();
    try std.testing.expectEqual(@as(u64, reference.written().len), body.contentLength());

    const source = body.source();
    try std.testing.expect(source.canReset());

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    var one: [1]u8 = undefined;
    while (true) {
        const n = try source.read(&one);
        if (n == 0) break;
        try got.appendSlice(std.testing.allocator, one[0..n]);
    }
    try std.testing.expectEqualStrings(reference.written(), got.items);
}

test "streaming body source replays after reset and tolerates large reads" {
    const boundary = "replay-boundary";
    const parts = [_]Part{
        .{ .name = "a", .data = "alpha" },
        .{ .name = "b", .data = "beta" },
    };
    var body = try StreamingBody.init(std.testing.allocator, boundary, &parts);
    defer body.deinit();
    const source = body.source();

    var buf: [4096]u8 = undefined;
    const first = try source.read(&buf);
    try std.testing.expectEqual(body.contentLength(), @as(u64, first));
    try std.testing.expectEqual(@as(usize, 0), try source.read(&buf));

    try source.reset();
    const second = try source.read(&buf);
    try std.testing.expectEqualStrings(buf[0..first], buf[0..second]);
}
