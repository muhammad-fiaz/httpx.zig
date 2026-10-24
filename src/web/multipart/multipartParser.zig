//! Multipart parsing — RFC 2046, RFC 7578, RFC 8187.
//!
//! In-memory parser with configurable limits and a bounded incremental
//! stream parser. Part bodies borrow the input buffer for the in-memory
//! parser; all header metadata is owned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parseMod = @import("../../common/parse.zig");
const common = @import("multipartCommon.zig");

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
    /// Maximum number of headers per part (0 = unlimited).
    maxHeaders: usize = 128,
    /// Maximum single part body size in bytes (0 = unlimited).
    maxPartSize: usize = 16 * 1024 * 1024,
    /// Maximum total part body size in bytes (0 = unlimited).
    maxTotalSize: usize = 64 * 1024 * 1024,
    /// Maximum field name length.
    maxFieldName: usize = 1024,
    /// Maximum filename length.
    maxFilename: usize = 4096,
    /// Maximum Content-Type value length.
    maxContentType: usize = 4096,
    /// Maximum preamble size (0 = unlimited).
    maxPreambleSize: usize = 64 * 1024,
    /// Maximum epilogue size (0 = unlimited).
    maxEpilogueSize: usize = 64 * 1024,
    /// Maximum wire bytes (0 = unlimited).
    maxWireSize: usize = 128 * 1024 * 1024,
    /// Maximum buffered bytes in StreamParser (0 = unlimited).
    maxBuffered: usize = 1024 * 1024,

    pub const strict = Limits{
        .maxBoundaryLen = 70,
        .maxParts = 256,
        .maxHeaderLine = 4096,
        .maxHeadersSize = 8192,
        .maxHeaders = 64,
        .maxPartSize = 10 * 1024 * 1024,
        .maxTotalSize = 50 * 1024 * 1024,
        .maxFieldName = 512,
        .maxFilename = 1024,
        .maxContentType = 1024,
        .maxPreambleSize = 16 * 1024,
        .maxEpilogueSize = 16 * 1024,
        .maxWireSize = 64 * 1024 * 1024,
        .maxBuffered = 256 * 1024,
    };

    pub const relaxed = Limits{
        .maxBoundaryLen = 70,
        .maxParts = 8192,
        .maxHeaderLine = 16384,
        .maxHeadersSize = 65536,
        .maxHeaders = 512,
        .maxPartSize = 0,
        .maxTotalSize = 0,
        .maxFieldName = 4096,
        .maxFilename = 16384,
        .maxContentType = 16384,
        .maxPreambleSize = 0,
        .maxEpilogueSize = 0,
        .maxWireSize = 0,
        .maxBuffered = 0,
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
    /// Raw RFC 8187 value as it appeared in the header.
    value: []const u8 = "",
    /// Percent-decoded bytes. For UTF-8 this is the preferred filename.
    decoded: []const u8 = "",
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Returns the best available filename, preferring a decoded UTF-8
/// `filename*` when present.
pub fn effectiveFilename(field: *const Field) ?[]const u8 {
    if (field.filenameStar) |fs| {
        if ((fs.charset.len == 0 or std.ascii.eqlIgnoreCase(fs.charset, "UTF-8")) and
            fs.decoded.len > 0)
            return fs.decoded;
    }
    return field.filename;
}

// Errors

pub const ParseError = error{
    MissingBoundary,
    Malformed,
    BoundaryTooLong,
    TooManyParts,
    HeaderLineTooLong,
    HeadersTooLarge,
    TooManyHeaders,
    PartTooLarge,
    BodyTooLarge,
    InvalidBoundary,
    MissingDisposition,
    MissingName,
    InvalidHeader,
    InvalidParameter,
    InvalidPercentEncoding,
    DuplicateHeader,
    FieldTooLong,
    FilenameTooLong,
    ContentTypeTooLong,
    PreambleTooLarge,
    EpilogueTooLarge,
    BufferTooLarge,
    UnexpectedEof,
    OutOfMemory,
};

// Parser

pub const Parser = struct {
    allocator: Allocator,
    limits: Limits,

    pub fn init(allocator: Allocator, limits: Limits) Parser {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn parse(self: *Parser, body: []const u8, boundary: []const u8) ParseError![]Field {
        return parseMultipart(self.allocator, body, boundary, self.limits);
    }

    pub fn parseFormData(self: *Parser, body: []const u8, boundary: []const u8) ParseError![]Field {
        return parseMultipartInternal(self.allocator, body, boundary, self.limits, true);
    }

    pub fn parseContentType(self: *Parser, body: []const u8, contentType: []const u8) ParseError![]Field {
        return parseBody(self.allocator, body, contentType, self.limits);
    }
};

/// An incremental parser event. `partBegin` metadata borrows the parser's
/// scratch arena and remains valid only until the next call to `next()`.
/// `partData` is an owned allocation from the parser allocator; the caller
/// must free it after consuming it. `partEnd` and `done` own no memory.
pub const StreamEvent = union(enum) {
    partBegin: struct {
        name: []const u8,
        filename: ?[]const u8 = null,
        filenameStar: ?FilenameStar = null,
        contentType: []const u8 = "",
    },
    partData: []const u8,
    partEnd,
    done,
};

pub const StreamParser = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    boundary: []const u8,
    delimBuf: [72]u8 = undefined,
    delimLen: usize = 0,
    limits: Limits,
    require_form_data: bool = false,
    buffer: std.ArrayList(u8),
    state: State = .preamble,
    partCount: usize = 0,
    currentPartSize: usize = 0,
    totalSize: usize = 0,
    wireSize: usize = 0,
    preambleSize: usize = 0,
    epilogueSize: usize = 0,
    eof: bool = false,

    const State = enum {
        preamble,
        after_opening,
        headers,
        body,
        delimiter,
        finished,
        closed,
    };

    pub fn init(allocator: Allocator, boundary: []const u8, limits: Limits) ParseError!StreamParser {
        return initWithSubtype(allocator, boundary, true, limits);
    }

    pub fn initWithSubtype(
        allocator: Allocator,
        boundary: []const u8,
        require_form_data: bool,
        limits: Limits,
    ) ParseError!StreamParser {
        if (boundary.len == 0) return ParseError.InvalidBoundary;
        if (boundary.len > limits.maxBoundaryLen) return ParseError.BoundaryTooLong;
        if (!common.validateBoundary(boundary)) return ParseError.InvalidBoundary;

        var sp = StreamParser{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .boundary = boundary,
            .limits = limits,
            .require_form_data = require_form_data,
            .buffer = .empty,
        };
        const d = std.fmt.bufPrint(&sp.delimBuf, "--{s}", .{boundary}) catch return ParseError.InvalidBoundary;
        sp.delimLen = d.len;
        return sp;
    }

    pub fn deinit(self: *StreamParser) void {
        self.buffer.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn getDelim(self: *const StreamParser) []const u8 {
        return self.delimBuf[0..self.delimLen];
    }

    pub fn feed(self: *StreamParser, chunk: []const u8) ParseError!void {
        self.wireSize = std.math.add(usize, self.wireSize, chunk.len) catch return ParseError.BodyTooLarge;
        if (self.limits.maxWireSize > 0 and self.wireSize > self.limits.maxWireSize)
            return ParseError.BodyTooLarge;

        if (self.state == .finished or self.state == .closed) {
            self.epilogueSize = std.math.add(usize, self.epilogueSize, chunk.len) catch
                return ParseError.EpilogueTooLarge;
            if (self.limits.maxEpilogueSize > 0 and self.epilogueSize > self.limits.maxEpilogueSize)
                return ParseError.EpilogueTooLarge;
            return;
        }

        const buffered_size = std.math.add(usize, self.buffer.items.len, chunk.len) catch
            return ParseError.BufferTooLarge;
        if (self.limits.maxBuffered > 0 and buffered_size > self.limits.maxBuffered)
            return ParseError.BufferTooLarge;
        self.buffer.appendSlice(self.allocator, chunk) catch return ParseError.OutOfMemory;
    }

    pub fn finish(self: *StreamParser) ParseError!void {
        if (self.eof) return;
        self.eof = true;
        switch (self.state) {
            .preamble => return ParseError.MissingBoundary,
            .after_opening, .headers, .body, .delimiter => return ParseError.UnexpectedEof,
            .finished, .closed => {},
        }
    }

    fn dropFront(self: *StreamParser, count: usize) void {
        if (count == 0) return;
        const remaining = self.buffer.items.len - count;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[count..]);
        self.buffer.items.len = remaining;
    }

    fn addPartData(self: *StreamParser, data: []const u8) ParseError!void {
        self.currentPartSize = std.math.add(usize, self.currentPartSize, data.len) catch
            return ParseError.PartTooLarge;
        self.totalSize = std.math.add(usize, self.totalSize, data.len) catch
            return ParseError.BodyTooLarge;
        if (self.limits.maxPartSize > 0 and self.currentPartSize > self.limits.maxPartSize)
            return ParseError.PartTooLarge;
        if (self.limits.maxTotalSize > 0 and self.totalSize > self.limits.maxTotalSize)
            return ParseError.BodyTooLarge;
    }

    /// Advances parsing and returns the next event, or null when more input is
    /// needed. Metadata from a returned `partBegin` must be copied before the
    /// next call; each call resets the scratch arena. The caller owns and must
    /// free every `partData` slice with the allocator passed to `init`.
    pub fn next(self: *StreamParser) ParseError!?StreamEvent {
        _ = self.arena.reset(.retain_capacity);
        while (true) {
            switch (self.state) {
                .preamble => {
                    const delim = self.getDelim();
                    if (findDelimiter(self.buffer.items, 0, delim)) |pos| {
                        if (self.limits.maxPreambleSize > 0 and pos > self.limits.maxPreambleSize)
                            return ParseError.PreambleTooLarge;
                        self.dropFront(pos);
                        self.state = .after_opening;
                        continue;
                    }
                    const keep = @min(self.buffer.items.len, delim.len + 4);
                    const drop = self.buffer.items.len - keep;
                    if (drop > 0) {
                        self.preambleSize = std.math.add(usize, self.preambleSize, drop) catch
                            return ParseError.PreambleTooLarge;
                        if (self.limits.maxPreambleSize > 0 and self.preambleSize > self.limits.maxPreambleSize)
                            return ParseError.PreambleTooLarge;
                        self.dropFront(drop);
                    }
                    return null;
                },
                .after_opening => {
                    const delim = self.getDelim();
                    if (self.buffer.items.len < delim.len + 2) return null;
                    const after = delim.len;
                    if (self.buffer.items[after] == '-' and self.buffer.items[after + 1] == '-') {
                        const rest = self.buffer.items[after + 2 ..].len;
                        if (self.limits.maxEpilogueSize > 0 and rest > self.limits.maxEpilogueSize)
                            return ParseError.EpilogueTooLarge;
                        self.buffer.clearRetainingCapacity();
                        self.state = .closed;
                        return StreamEvent.done;
                    }
                    if (self.buffer.items[after] == '\r' and self.buffer.items[after + 1] == '\n') {
                        self.dropFront(after + 2);
                        self.state = .headers;
                        continue;
                    }
                    return ParseError.Malformed;
                },
                .headers => {
                    const headers_end = try scanHeadersEnd(self.buffer.items, self.limits) orelse return null;
                    if (self.limits.maxParts > 0 and self.partCount >= self.limits.maxParts)
                        return ParseError.TooManyParts;

                    const raw = self.buffer.items[0..headers_end];
                    const meta = try parsePartHeaders(
                        self.arena.allocator(),
                        raw,
                        self.limits,
                        self.require_form_data,
                    );

                    self.partCount += 1;
                    self.currentPartSize = 0;
                    self.dropFront(headers_end + 2);
                    self.state = .body;

                    return StreamEvent{ .partBegin = .{
                        .name = meta.name,
                        .filename = meta.filename,
                        .filenameStar = meta.filename_star,
                        .contentType = meta.content_type,
                    } };
                },
                .body => {
                    const delim = self.getDelim();
                    if (findDelimiter(self.buffer.items, 0, delim)) |pos| {
                        var dataEnd = pos;
                        if (pos > 0) {
                            if (pos >= 2 and self.buffer.items[pos - 2] == '\r' and self.buffer.items[pos - 1] == '\n') {
                                dataEnd = pos - 2;
                            } else if (self.buffer.items[pos - 1] == '\n') {
                                dataEnd = pos - 1;
                            } else {
                                return ParseError.Malformed;
                            }
                        }
                        if (dataEnd > 0) {
                            const data = self.buffer.items[0..dataEnd];
                            try self.addPartData(data);
                            const out = self.allocator.dupe(u8, data) catch return ParseError.OutOfMemory;
                            self.dropFront(pos);
                            self.state = .delimiter;
                            return StreamEvent{ .partData = out };
                        }
                        self.state = .delimiter;
                        continue;
                    }

                    const keep = @min(self.buffer.items.len, delim.len + 4);
                    const emitLen = self.buffer.items.len - keep;
                    if (emitLen == 0) return null;
                    const data = self.buffer.items[0..emitLen];
                    try self.addPartData(data);
                    const out = self.allocator.dupe(u8, data) catch return ParseError.OutOfMemory;
                    self.dropFront(emitLen);
                    return StreamEvent{ .partData = out };
                },
                .delimiter => {
                    const delim = self.getDelim();
                    if (self.buffer.items.len < delim.len + 2) return null;
                    const after = delim.len;
                    if (self.buffer.items[after] == '-' and self.buffer.items[after + 1] == '-') {
                        const rest = self.buffer.items[after + 2 ..].len;
                        if (self.limits.maxEpilogueSize > 0 and rest > self.limits.maxEpilogueSize)
                            return ParseError.EpilogueTooLarge;
                        self.buffer.clearRetainingCapacity();
                        self.state = .finished;
                        return StreamEvent.partEnd;
                    }
                    if (self.buffer.items[after] == '\r' and self.buffer.items[after + 1] == '\n') {
                        self.dropFront(after + 2);
                        self.state = .headers;
                        return StreamEvent.partEnd;
                    }
                    return ParseError.Malformed;
                },
                .finished => {
                    self.state = .closed;
                    return StreamEvent.done;
                },
                .closed => return null,
            }
        }
    }
};

/// Parses a full multipart body with default limits. Field names, filenames,
/// and Content-Type values are owned; release with `freeFields`.
pub fn parse(allocator: Allocator, body: []const u8, boundary: []const u8) ParseError![]Field {
    return parseMultipart(allocator, body, boundary, .{});
}

/// Parses a complete body and requires `multipart/form-data` part semantics.
pub fn parseFormData(allocator: Allocator, body: []const u8, boundary: []const u8, limits: Limits) ParseError![]Field {
    return parseMultipartInternal(allocator, body, boundary, limits, true);
}

/// Extracts the boundary and subtype from a Content-Type header and parses the
/// body. `multipart/form-data` inputs require a valid name parameter.
pub fn parseBody(allocator: Allocator, body: []const u8, contentType: []const u8, limits: Limits) ParseError![]Field {
    const boundary = extractBoundary(contentType) orelse return ParseError.MissingBoundary;
    const subtype = detectSubtype(contentType);
    const require_form_data = if (subtype) |s| std.ascii.eqlIgnoreCase(s, "form-data") else false;
    return parseMultipartInternal(allocator, body, boundary, limits, require_form_data);
}

/// Parses with custom allocator and limits. For multipart/form-data use
/// `parseFormData` or `parseBody` so missing names are rejected.
pub fn parseMultipart(allocator: Allocator, body: []const u8, boundary: []const u8, limits: Limits) ParseError![]Field {
    return parseMultipartInternal(allocator, body, boundary, limits, false);
}

fn parseMultipartInternal(
    allocator: Allocator,
    body: []const u8,
    boundary: []const u8,
    limits: Limits,
    require_form_data: bool,
) ParseError![]Field {
    if (boundary.len == 0) return ParseError.InvalidBoundary;
    if (boundary.len > limits.maxBoundaryLen) return ParseError.BoundaryTooLong;
    if (!common.validateBoundary(boundary)) return ParseError.InvalidBoundary;
    if (limits.maxWireSize > 0 and body.len > limits.maxWireSize) return ParseError.BodyTooLarge;

    var delimBuf: [72]u8 = undefined;
    const delim = std.fmt.bufPrint(&delimBuf, "--{s}", .{boundary}) catch return ParseError.InvalidBoundary;

    const firstPos = findDelimiter(body, 0, delim) orelse return ParseError.MissingBoundary;
    if (limits.maxPreambleSize > 0 and firstPos > limits.maxPreambleSize)
        return ParseError.PreambleTooLarge;

    var cursor = firstPos + delim.len;
    if (cursor + 2 > body.len) return ParseError.Malformed;
    if (body[cursor] == '-' and body[cursor + 1] == '-') {
        try checkEpilogue(body[cursor + 2 ..], limits);
        return allocator.alloc(Field, 0) catch return ParseError.OutOfMemory;
    }
    if (body[cursor] != '\r' or body[cursor + 1] != '\n') return ParseError.Malformed;
    cursor += 2;

    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |*f| freeField(allocator, f);
        fields.deinit(allocator);
    }

    var partCount: usize = 0;
    var totalSize: usize = 0;

    while (true) {
        if (limits.maxParts > 0 and partCount >= limits.maxParts) return ParseError.TooManyParts;

        const header_end = try scanHeadersEnd(body[cursor..], limits) orelse return ParseError.Malformed;
        const rawHeaders = body[cursor .. cursor + header_end];
        var meta = try parsePartHeaders(allocator, rawHeaders, limits, require_form_data);
        var meta_transferred = false;
        errdefer if (!meta_transferred) freePartMeta(allocator, &meta);

        const dataStart = cursor + header_end + 2;
        const nextDelim = findDelimiter(body, dataStart, delim) orelse return ParseError.Malformed;

        var dataEnd = nextDelim;
        if (nextDelim > dataStart) {
            if (nextDelim >= 2 and body[nextDelim - 2] == '\r' and body[nextDelim - 1] == '\n') {
                dataEnd = nextDelim - 2;
            } else if (body[nextDelim - 1] == '\n') {
                dataEnd = nextDelim - 1;
            } else {
                return ParseError.Malformed;
            }
        }
        const partData = body[dataStart..dataEnd];

        totalSize = std.math.add(usize, totalSize, partData.len) catch return ParseError.BodyTooLarge;
        if (limits.maxPartSize > 0 and partData.len > limits.maxPartSize)
            return ParseError.PartTooLarge;
        if (limits.maxTotalSize > 0 and totalSize > limits.maxTotalSize)
            return ParseError.BodyTooLarge;

        fields.append(allocator, .{
            .name = meta.name,
            .filename = meta.filename,
            .filenameStar = meta.filename_star,
            .contentType = meta.content_type,
            .contentTransferEncoding = meta.cte,
            .data = partData,
            .headers = meta.headers,
        }) catch {
            freePartMeta(allocator, &meta);
            return ParseError.OutOfMemory;
        };
        meta_transferred = true;
        partCount += 1;

        cursor = nextDelim + delim.len;
        if (cursor + 2 <= body.len and body[cursor] == '-' and body[cursor + 1] == '-') {
            try checkEpilogue(body[cursor + 2 ..], limits);
            return fields.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        }
        if (cursor + 2 > body.len or body[cursor] != '\r' or body[cursor + 1] != '\n')
            return ParseError.Malformed;
        cursor += 2;
    }
}

fn checkEpilogue(epilogue: []const u8, limits: Limits) ParseError!void {
    if (limits.maxEpilogueSize > 0 and epilogue.len > limits.maxEpilogueSize)
        return ParseError.EpilogueTooLarge;
}

pub fn freeFields(allocator: Allocator, fields: []Field) void {
    freeFieldsAlloc(allocator, fields);
}

pub fn freeFieldsAlloc(allocator: Allocator, fields: []Field) void {
    for (fields) |*f| freeField(allocator, f);
    allocator.free(fields);
}

fn freePartMeta(allocator: Allocator, meta: *PartMeta) void {
    freeOwned(allocator, meta.name);
    if (meta.filename) |v| freeOwned(allocator, v);
    if (meta.filename_star) |*fs| freeFilenameStar(allocator, fs);
    freeOwned(allocator, meta.content_type);
    if (meta.cte) |v| freeOwned(allocator, v);
    for (meta.headers) |h| {
        freeOwned(allocator, h.name);
        freeOwned(allocator, h.value);
    }
    if (meta.headers.len > 0) allocator.free(meta.headers);
}

fn freeField(allocator: Allocator, field: *Field) void {
    freeOwned(allocator, field.name);
    if (field.filename) |v| freeOwned(allocator, v);
    if (field.filenameStar) |*fs| freeFilenameStar(allocator, fs);
    freeOwned(allocator, field.contentType);
    if (field.contentTransferEncoding) |v| freeOwned(allocator, v);
    for (field.headers) |h| {
        freeOwned(allocator, h.name);
        freeOwned(allocator, h.value);
    }
    if (field.headers.len > 0) allocator.free(field.headers);
}

fn freeFilenameStar(allocator: Allocator, fs: *FilenameStar) void {
    freeOwned(allocator, fs.charset);
    freeOwned(allocator, fs.language);
    freeOwned(allocator, fs.value);
    freeOwned(allocator, fs.decoded);
}

fn freeOwned(allocator: Allocator, value: []const u8) void {
    if (value.len > 0) allocator.free(value);
}

fn freeOwnedMaybe(allocator: Allocator, value: ?[]const u8) void {
    if (value) |v| freeOwned(allocator, v);
}

// Extract boundary from Content-Type

pub fn extractBoundary(contentType: []const u8) ?[]const u8 {
    var it = parseMod.ParamIterator.init(contentType);
    _ = it.next();
    while (it.next()) |param| {
        if (parseMod.eqlIgnoreCase(param.key, "boundary")) {
            var value = parseMod.trimOws(param.value);
            if (value.len >= 2 and value[0] == '"') {
                if (value[value.len - 1] != '"') return null;
                value = value[1 .. value.len - 1];
                if (std.mem.indexOfAny(u8, value, "\"\\") != null) return null;
            }
            return value;
        }
    }
    return null;
}

// Subtype detection

pub fn detectSubtype(contentType: []const u8) ?[]const u8 {
    var it = parseMod.ParamIterator.init(contentType);
    const mainParam = it.next() orelse return null;
    const main = parseMod.trimOws(mainParam.key);
    if (main.len <= "multipart/".len) return null;
    if (!std.ascii.eqlIgnoreCase(main[0.."multipart/".len], "multipart/")) return null;
    const subtype = main["multipart/".len..];
    if (!common.isToken(subtype)) return null;
    return subtype;
}

// Internal helpers

const PartMeta = struct {
    name: []const u8 = "",
    filename: ?[]const u8 = null,
    filename_star: ?FilenameStar = null,
    content_type: []const u8 = "",
    cte: ?[]const u8 = null,
    headers: []const Header = &.{},
};

const ParsedDisposition = struct {
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    filename_star: ?FilenameStar = null,
};

fn parsePartHeaders(
    allocator: Allocator,
    rawHeaders: []const u8,
    limits: Limits,
    require_form_data: bool,
) ParseError!PartMeta {
    var cd: ?[]const u8 = null;
    var ct: ?[]const u8 = null;
    var cte: ?[]const u8 = null;
    var seen_cd = false;
    var seen_ct = false;
    var seen_cte = false;

    var extra: std.ArrayList(Header) = .empty;
    errdefer {
        for (extra.items) |h| {
            freeOwned(allocator, h.name);
            freeOwned(allocator, h.value);
        }
        extra.deinit(allocator);
    }

    var header_count: usize = 0;
    var pos: usize = 0;
    while (pos < rawHeaders.len) {
        const line_end = std.mem.indexOfPos(u8, rawHeaders, pos, "\r\n") orelse rawHeaders.len;
        const line = rawHeaders[pos..line_end];
        pos = if (line_end < rawHeaders.len) line_end + 2 else rawHeaders.len;
        if (line.len == 0) continue;

        if (line[0] == ' ' or line[0] == '\t') return ParseError.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.InvalidHeader;
        const name = parseMod.trimOws(line[0..colon]);
        const value = parseMod.trimOws(line[colon + 1 ..]);
        if (!common.isToken(name) or !common.isHeaderValueSafe(value)) return ParseError.InvalidHeader;

        header_count = std.math.add(usize, header_count, 1) catch return ParseError.TooManyHeaders;
        if (limits.maxHeaders > 0 and header_count > limits.maxHeaders) return ParseError.TooManyHeaders;

        if (std.ascii.eqlIgnoreCase(name, "Content-Disposition")) {
            if (seen_cd) return ParseError.DuplicateHeader;
            seen_cd = true;
            cd = value;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (seen_ct) return ParseError.DuplicateHeader;
            seen_ct = true;
            ct = value;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Transfer-Encoding")) {
            if (seen_cte) return ParseError.DuplicateHeader;
            seen_cte = true;
            if (!common.isToken(value)) return ParseError.InvalidHeader;
            cte = value;
        } else {
            const extra_name = try dupeOrEmpty(allocator, name);
            const extra_value = dupeOrEmpty(allocator, value) catch |err| {
                freeOwned(allocator, extra_name);
                return err;
            };
            extra.append(allocator, .{ .name = extra_name, .value = extra_value }) catch {
                freeOwned(allocator, extra_name);
                freeOwned(allocator, extra_value);
                return ParseError.OutOfMemory;
            };
        }
    }

    var meta = PartMeta{};
    errdefer {
        freePartMeta(allocator, &meta);
    }

    if (cd) |value| {
        var parsed = try parseContentDisposition(allocator, value, limits, require_form_data);
        errdefer freeParsedDisposition(allocator, &parsed);
        meta.name = parsed.name orelse "";
        meta.filename = parsed.filename;
        meta.filename_star = parsed.filename_star;
        parsed.name = null;
        parsed.filename = null;
        parsed.filename_star = null;
    } else if (require_form_data) {
        return ParseError.MissingDisposition;
    }

    if (ct) |value| {
        if (limits.maxContentType > 0 and value.len > limits.maxContentType)
            return ParseError.ContentTypeTooLong;
        meta.content_type = try dupeOrEmpty(allocator, value);
    }
    if (cte) |value| {
        meta.cte = try dupeOrEmpty(allocator, value);
    }

    if (extra.items.len > 0) {
        meta.headers = extra.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    } else {
        extra.deinit(allocator);
    }
    return meta;
}

fn parseContentDisposition(
    allocator: Allocator,
    value: []const u8,
    limits: Limits,
    require_form_data: bool,
) ParseError!ParsedDisposition {
    var pos: usize = 0;
    skipOws(value, &pos);
    const type_start = pos;
    while (pos < value.len and isTokenChar(value[pos])) pos += 1;
    if (pos == type_start) return ParseError.InvalidParameter;
    const disposition = value[type_start..pos];
    skipOws(value, &pos);

    var result = ParsedDisposition{};
    errdefer freeParsedDisposition(allocator, &result);

    while (pos < value.len) {
        if (value[pos] != ';') return ParseError.InvalidParameter;
        pos += 1;
        skipOws(value, &pos);
        if (pos >= value.len) break;

        const key_start = pos;
        while (pos < value.len and isTokenChar(value[pos])) pos += 1;
        if (pos == key_start) return ParseError.InvalidParameter;
        const key = value[key_start..pos];
        skipOws(value, &pos);
        if (pos >= value.len or value[pos] != '=') return ParseError.InvalidParameter;
        pos += 1;
        skipOws(value, &pos);

        var owned = true;
        var param_value: []const u8 = undefined;
        if (pos < value.len and value[pos] == '"') {
            param_value = try parseQuotedValue(allocator, value, &pos);
        } else {
            const start = pos;
            while (pos < value.len and value[pos] != ';') pos += 1;
            param_value = parseMod.trimOws(value[start..pos]);
            if (!common.isQuotedStringSafe(param_value)) return ParseError.InvalidParameter;
            if (param_value.len == 0) return ParseError.InvalidParameter;
            param_value = allocator.dupe(u8, param_value) catch return ParseError.OutOfMemory;
            owned = true;
        }
        skipOws(value, &pos);

        if (std.ascii.eqlIgnoreCase(key, "name")) {
            if (result.name != null) {
                freeOwned(allocator, param_value);
                return ParseError.InvalidParameter;
            }
            if (limits.maxFieldName > 0 and param_value.len > limits.maxFieldName) {
                freeOwned(allocator, param_value);
                return ParseError.FieldTooLong;
            }
            result.name = try dupeOrEmptyOwned(allocator, param_value);
            freeOwned(allocator, param_value);
        } else if (std.ascii.eqlIgnoreCase(key, "filename")) {
            if (result.filename != null) {
                freeOwned(allocator, param_value);
                return ParseError.InvalidParameter;
            }
            if (limits.maxFilename > 0 and param_value.len > limits.maxFilename) {
                freeOwned(allocator, param_value);
                return ParseError.FilenameTooLong;
            }
            result.filename = try dupeOrEmptyOwned(allocator, param_value);
            freeOwned(allocator, param_value);
        } else if (std.ascii.eqlIgnoreCase(key, "filename*")) {
            if (result.filename_star != null) {
                freeOwned(allocator, param_value);
                return ParseError.InvalidParameter;
            }
            const fs = parseExtendedValue(allocator, param_value, limits) catch |err| {
                freeOwned(allocator, param_value);
                return err;
            };
            freeOwned(allocator, param_value);
            result.filename_star = fs;
        } else if (owned) {
            freeOwned(allocator, param_value);
        }
    }

    if (require_form_data) {
        if (!std.ascii.eqlIgnoreCase(disposition, "form-data"))
            return ParseError.MissingDisposition;
        if (result.name == null) return ParseError.MissingName;
    } else if (std.ascii.eqlIgnoreCase(disposition, "form-data")) {
        if (result.name == null) return ParseError.MissingName;
    }
    return result;
}

fn parseExtendedValue(allocator: Allocator, raw: []const u8, limits: Limits) ParseError!FilenameStar {
    const first = std.mem.indexOfScalar(u8, raw, '\'') orelse return ParseError.InvalidParameter;
    const second_rel = std.mem.indexOfScalar(u8, raw[first + 1 ..], '\'') orelse
        return ParseError.InvalidParameter;
    const second = first + 1 + second_rel;

    const charset = raw[0..first];
    const language = raw[first + 1 .. second];
    const encoded = raw[second + 1 ..];
    if (!common.isToken(charset)) return ParseError.InvalidParameter;
    if (language.len > 0 and !common.isToken(language)) return ParseError.InvalidParameter;
    if (limits.maxFilename > 0 and encoded.len > limits.maxFilename)
        return ParseError.FilenameTooLong;

    const decoded = common.percentDecode(allocator, encoded) catch |err| switch (err) {
        error.InvalidPercentEncoding => return ParseError.InvalidPercentEncoding,
        error.OutOfMemory => return ParseError.OutOfMemory,
    };
    errdefer allocator.free(decoded);
    if (!common.isQuotedStringSafe(decoded)) return ParseError.InvalidParameter;

    return .{
        .charset = try dupeOrEmpty(allocator, charset),
        .language = try dupeOrEmpty(allocator, language),
        .value = try dupeOrEmpty(allocator, encoded),
        .decoded = if (decoded.len > 0) decoded else blk: {
            allocator.free(decoded);
            break :blk "";
        },
    };
}

fn parseQuotedValue(allocator: Allocator, value: []const u8, pos: *usize) ParseError![]u8 {
    pos.* += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (pos.* < value.len) {
        const c = value[pos.*];
        if (c == '"') {
            pos.* += 1;
            return out.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        }
        if (c == '\\') {
            pos.* += 1;
            if (pos.* >= value.len) return ParseError.InvalidParameter;
            const escaped = value[pos.*];
            if (escaped == '\r' or escaped == '\n' or escaped == 0) return ParseError.InvalidParameter;
            out.append(allocator, escaped) catch return ParseError.OutOfMemory;
            pos.* += 1;
        } else {
            if (c == '\r' or c == '\n' or c == 0 or (c < 0x20 and c != '\t'))
                return ParseError.InvalidParameter;
            out.append(allocator, c) catch return ParseError.OutOfMemory;
            pos.* += 1;
        }
    }
    return ParseError.InvalidParameter;
}

fn freeParsedDisposition(allocator: Allocator, parsed: *ParsedDisposition) void {
    freeOwnedMaybe(allocator, parsed.name);
    freeOwnedMaybe(allocator, parsed.filename);
    if (parsed.filename_star) |*fs| freeFilenameStar(allocator, fs);
}

fn dupeOrEmpty(allocator: Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return "";
    return allocator.dupe(u8, value) catch return ParseError.OutOfMemory;
}

fn dupeOrEmptyOwned(allocator: Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return "";
    return allocator.dupe(u8, value) catch return ParseError.OutOfMemory;
}

fn skipOws(value: []const u8, pos: *usize) void {
    while (pos.* < value.len and (value[pos.*] == ' ' or value[pos.*] == '\t')) pos.* += 1;
}

fn isTokenChar(c: u8) bool {
    if (c <= 0x20 or c >= 0x7f) return false;
    return switch (c) {
        '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => false,
        else => true,
    };
}

fn findDelimiter(body: []const u8, from: usize, delim: []const u8) ?usize {
    if (from > body.len) return null;
    var search = from;
    while (std.mem.indexOfPos(u8, body, search, delim)) |pos| {
        if (pos != from and (pos == 0 or body[pos - 1] != '\n')) {
            search = pos + 1;
            continue;
        }
        const after = pos + delim.len;
        if (after + 2 <= body.len) {
            if ((body[after] == '\r' and body[after + 1] == '\n') or
                (body[after] == '-' and body[after + 1] == '-'))
                return pos;
        }
        search = pos + 1;
    }
    return null;
}

fn scanHeadersEnd(data: []const u8, limits: Limits) ParseError!?usize {
    var pos: usize = 0;
    var total: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, data, pos, "\r\n") orelse {
            const remaining = data.len - pos;
            if (limits.maxHeaderLine > 0 and remaining > limits.maxHeaderLine)
                return ParseError.HeaderLineTooLong;
            if (limits.maxHeadersSize > 0 and data.len > limits.maxHeadersSize)
                return ParseError.HeadersTooLarge;
            return null;
        };
        const line_len = line_end - pos;
        if (limits.maxHeaderLine > 0 and line_len > limits.maxHeaderLine)
            return ParseError.HeaderLineTooLong;
        total = std.math.add(usize, total, line_len + 2) catch return ParseError.HeadersTooLarge;
        if (limits.maxHeadersSize > 0 and total > limits.maxHeadersSize)
            return ParseError.HeadersTooLarge;
        if (line_len == 0) return line_end;
        pos = line_end + 2;
    }
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

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("note", fields[0].name);
    try std.testing.expectEqualStrings("hello world", fields[0].data);
    try std.testing.expect(fields[0].filename == null);

    try std.testing.expectEqualStrings("f", fields[1].name);
    try std.testing.expectEqualStrings("a.bin", fields[1].filename.?);
    try std.testing.expectEqualStrings("\x00\x01\xff\x00binary", fields[1].data);
}

test "rejects missing final delimiter and wrong boundary" {
    try std.testing.expectError(ParseError.MissingBoundary, parse(std.testing.allocator, "--NOPE--\r\n", "X"));
    try std.testing.expectError(ParseError.Malformed, parse(
        std.testing.allocator,
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\ndata",
        "B",
    ));
}

test "parseMultipart roundtrip frees without leaks" {
    const a = std.testing.allocator;
    const boundary = "XBOUND";
    const body =
        "--XBOUND\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "X-Custom: yes\r\n" ++
        "\r\n" ++
        "data\r\n" ++
        "--XBOUND--\r\n";
    const fields = try parseMultipart(a, body, boundary, .{});
    defer freeFieldsAlloc(a, fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqual(@as(usize, 1), fields[0].headers.len);
    try std.testing.expectEqualStrings("X-Custom", fields[0].headers[0].name);
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

    var p = Parser.init(std.heap.page_allocator, .{ .maxParts = 1 });
    try std.testing.expectError(ParseError.TooManyParts, p.parse(body, boundary));
}

test "parser accepts exactly maxParts" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
        "--B--\r\n";
    var p = Parser.init(std.testing.allocator, .{ .maxParts = 1 });
    const fields = try p.parse(body, boundary);
    defer freeFieldsAlloc(std.testing.allocator, fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
}

test "parser respects maxPartSize limit" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n12345\r\n" ++
        "--B--\r\n";

    var p = Parser.init(std.heap.page_allocator, .{ .maxPartSize = 3 });
    try std.testing.expectError(ParseError.PartTooLarge, p.parse(body, boundary));
}

test "parses filename* parameter and decodes UTF-8" {
    const boundary = "B";
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename*=UTF-8''test-%C3%A9.txt\r\n" ++
        "\r\n" ++
        "data\r\n" ++
        "--B--\r\n";

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expect(fields[0].filenameStar != null);
    try std.testing.expectEqualStrings("UTF-8", fields[0].filenameStar.?.charset);
    try std.testing.expectEqualStrings("test-%C3%A9.txt", fields[0].filenameStar.?.value);
    try std.testing.expectEqualStrings("test-é.txt", fields[0].filenameStar.?.decoded);
    try std.testing.expectEqualStrings("test-é.txt", effectiveFilename(&fields[0]).?);
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

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("base64", fields[0].contentTransferEncoding.?);
}

test "empty parts list" {
    const boundary = "B";
    const body = "--B--\r\n";
    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);
    try std.testing.expectEqual(@as(usize, 0), fields.len);
}

test "parses multiple empty parts" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n\r\n" ++
        "--B--\r\n";

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

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

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("tag", fields[0].name);
    try std.testing.expectEqualStrings("foo", fields[0].data);
    try std.testing.expectEqualStrings("tag", fields[1].name);
    try std.testing.expectEqualStrings("bar", fields[1].data);
}

test "parser rejects invalid boundary length" {
    var p = Parser.init(std.heap.page_allocator, .{ .maxBoundaryLen = 5 });
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

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);

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

    var part1Name: ?[]u8 = null;
    defer if (part1Name) |p| a.free(p);
    var part1Data: std.ArrayList(u8) = .empty;
    defer part1Data.deinit(a);

    var part2Name: ?[]u8 = null;
    defer if (part2Name) |p| a.free(p);
    var part2Filename: ?[]u8 = null;
    defer if (part2Filename) |p| a.free(p);
    var part2Data: std.ArrayList(u8) = .empty;
    defer part2Data.deinit(a);

    var currentPart: usize = 0;
    var completedParts: usize = 0;

    while (try sp.next()) |ev| {
        switch (ev) {
            .partBegin => |pb| {
                currentPart += 1;
                if (currentPart == 1) {
                    part1Name = try a.dupe(u8, pb.name);
                } else if (currentPart == 2) {
                    part2Name = try a.dupe(u8, pb.name);
                    if (pb.filename) |f| part2Filename = try a.dupe(u8, f);
                }
            },
            .partData => |pd| {
                defer a.free(pd);
                if (currentPart == 1) {
                    try part1Data.appendSlice(a, pd);
                } else if (currentPart == 2) {
                    try part2Data.appendSlice(a, pd);
                }
            },
            .partEnd => {
                completedParts += 1;
            },
            .done => break,
        }
    }
    try sp.finish();

    try std.testing.expectEqual(@as(usize, 2), completedParts);
    try std.testing.expectEqualStrings("field1", part1Name.?);
    try std.testing.expectEqualStrings("value1", part1Data.items);
    try std.testing.expectEqualStrings("upload", part2Name.?);
    try std.testing.expectEqualStrings("test.txt", part2Filename.?);
    try std.testing.expectEqualStrings("file content line 1\nline 2", part2Data.items);
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
    try sp.finish();

    try std.testing.expectEqualStrings("incremental bytes stream", gathered.items);
}

test "StreamParser enforces maxBuffered without losing queued bytes" {
    var sp = try StreamParser.init(std.testing.allocator, "B", .{ .maxBuffered = 3 });
    defer sp.deinit();

    try sp.feed("abc");
    try std.testing.expectError(ParseError.BufferTooLarge, sp.feed("d"));
    try std.testing.expectEqualStrings("abc", sp.buffer.items);
}

test "boundary-like data with invalid suffix is not a delimiter" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n" ++
        "line\r\n--Bnot-a-delimiter\r\nstill data\r\n" ++
        "--B--\r\n";

    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("line\r\n--Bnot-a-delimiter\r\nstill data", fields[0].data);
}

test "form-data parser requires name and disposition" {
    const boundary = "B";
    const body1 =
        "--B\r\nContent-Disposition: attachment; filename=\"a.txt\"\r\n\r\ndata\r\n--B--\r\n";
    try std.testing.expectError(ParseError.MissingDisposition, parseMultipartInternal(
        std.testing.allocator,
        body1,
        boundary,
        .{},
        true,
    ));

    const body2 = "--B\r\nContent-Disposition: form-data; filename=\"a.txt\"\r\n\r\ndata\r\n--B--\r\n";
    try std.testing.expectError(ParseError.MissingName, parseMultipartInternal(
        std.testing.allocator,
        body2,
        boundary,
        .{},
        true,
    ));
}

test "quoted parameter escapes and duplicate parameters are handled" {
    const boundary = "B";
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\\\"b\"; filename=\"c\\\\d.txt\"\r\n" ++
        "\r\nx\r\n--B--\r\n";
    const fields = try parse(std.testing.allocator, body, boundary);
    defer freeFields(std.testing.allocator, fields);
    try std.testing.expectEqualStrings("a\"b", fields[0].name);
    try std.testing.expectEqualStrings("c\\d.txt", fields[0].filename.?);

    const dup = "--B\r\nContent-Disposition: form-data; name=\"a\"; name=\"b\"\r\n\r\nx\r\n--B--\r\n";
    try std.testing.expectError(ParseError.InvalidParameter, parse(std.testing.allocator, dup, boundary));
}

test "header limits are enforced before a header terminator arrives" {
    const boundary = "B";
    const body = "--B\r\nX-Long: " ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "\r\n\r\nx\r\n--B--\r\n";
    var p = Parser.init(std.testing.allocator, .{ .maxHeaderLine = 32 });
    try std.testing.expectError(ParseError.HeaderLineTooLong, p.parse(body, boundary));

    const no_terminator = "--B\r\nX-Long: " ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(ParseError.HeaderLineTooLong, p.parse(no_terminator, boundary));
}

test "preamble and epilogue limits" {
    const boundary = "B";
    const body = "preamble\r\n--B--\r\n" ++ "xxxxxxxxxx";
    var p = Parser.init(std.testing.allocator, .{ .maxPreambleSize = 4 });
    try std.testing.expectError(ParseError.PreambleTooLarge, p.parse(body, boundary));

    var p2 = Parser.init(std.testing.allocator, .{ .maxEpilogueSize = 4 });
    try std.testing.expectError(ParseError.EpilogueTooLarge, p2.parse("--B--\r\nxxxxxxxxxx", boundary));
}

test "StreamParser finish detects truncation" {
    var sp = try StreamParser.init(std.testing.allocator, "B", .{});
    defer sp.deinit();
    try sp.feed("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\ndata");
    while (try sp.next()) |ev| switch (ev) {
        .partData => |pd| std.testing.allocator.free(pd),
        else => {},
    };
    try std.testing.expectError(ParseError.UnexpectedEof, sp.finish());
}
