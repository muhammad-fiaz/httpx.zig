//! Incremental HTTP Message Parser for httpx.zig
//!
//! State-machine based parser for HTTP/1.x messages supporting:
//!
//! - Incremental parsing (feed data as it arrives)
//! - Request and response parsing
//! - Chunked transfer encoding
//! - Header limits for security
//! - Cross-platform compatible

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../core/types.zig");
const Headers = @import("../core/headers.zig").Headers;
const Status = @import("../core/status.zig").Status;

/// Parser state machine states.
pub const ParserState = enum {
    start,
    request_line,
    status_line,
    headers,
    body,
    chunk_size,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    complete,
    err,
};

/// Parser mode - request or response.
pub const ParserMode = enum {
    request,
    response,
};

/// Incremental HTTP message parser.
pub const Parser = struct {
    allocator: Allocator,
    state: ParserState = .start,
    mode: ParserMode = .request,
    method: ?types.Method = null,
    path: ?[]const u8 = null,
    version: types.Version = .HTTP_1_1,
    status_code: ?u16 = null,
    headers: Headers,
    body_buffer: std.ArrayList(u8) = .empty,
    content_length: ?u64 = null,
    chunked: bool = false,
    current_chunk_size: usize = 0,
    bytes_read: usize = 0,
    chunk_crlf_read: u2 = 0,
    line_buffer: std.ArrayList(u8) = .empty,
    max_header_size: usize = 8192,
    max_headers: usize = 100,
    header_bytes: usize = 0,
    header_count: usize = 0,
    /// When false, the parser will not enter body state for responses.
    /// Used for HEAD responses which have no body.
    expect_body: bool = true,
    /// Maximum body size in bytes. 0 means unlimited. Prevents memory exhaustion.
    max_body_size: usize = 100 * 1024 * 1024,
    /// Whether Connection: close was seen.
    connection_close: bool = false,
    /// Whether Connection: keep-alive was seen.
    connection_keep_alive: bool = false,
    /// Whether Transfer-Encoding header was seen (for conflict detection).
    transfer_encoding_seen: bool = false,
    /// HTTP compliance relaxations. Defaults are strict.
    compliance: types.ComplianceOptions = .{},

    const Self = @This();

    const Line = struct {
        /// Recognized line ending types. RFC 9112 §2.2 explicitly allows but
        /// does not require support for LF instead of CRLF.
        const Ending = enum(u2) { none = 0, lf = 1, crlf = 2 };

        const Options = struct {
            /// Whether to allow recognition of \n as line ending
            allow_lf: bool = false,
            /// Whether a previous unterminated line ended in \r
            preceding_cr: bool = false,
        };

        data: []const u8,

        /// The length of the line including its ending chars.
        len: usize,

        /// The line ending found; its integer value is the ending's byte length.
        ending: Ending,

        /// Locates the first line ending and initializes the Line.
        fn init(data: []const u8, options: Options) Line {
            if (options.preceding_cr and data.len > 0 and data[0] == '\n') {
                return .{ .data = data, .len = 1, .ending = .lf };
            }
            if (!options.allow_lf) {
                const i = mem.indexOf(u8, data, "\r\n") orelse
                    return .{ .data = data, .len = data.len, .ending = .none };
                return .{ .data = data, .len = i + 2, .ending = .crlf };
            }
            const i = mem.indexOfScalar(u8, data, '\n') orelse
                return .{ .data = data, .len = data.len, .ending = .none };
            const cr_before = i > 0 and data[i - 1] == '\r';
            return .{ .data = data, .len = i + 1, .ending = if (cr_before) .crlf else .lf };
        }

        /// Slice containing the line's text without ending
        fn text(self: Line) []const u8 {
            return self.data[0 .. self.len - @intFromEnum(self.ending)];
        }
    };

    /// Creates a new parser instance.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .headers = Headers.init(allocator),
        };
    }

    /// Creates a parser for parsing responses.
    pub fn initResponse(allocator: Allocator) Self {
        var p = init(allocator);
        p.mode = .response;
        p.state = .status_line;
        return p;
    }

    /// Releases all allocated memory.
    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.body_buffer.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
        if (self.path) |p| self.allocator.free(p);
    }

    /// Finalizes parsing when the underlying stream has reached EOF.
    ///
    /// For HTTP/1.x responses with neither `Content-Length` nor `Transfer-Encoding: chunked`,
    /// the body is delimited by connection close. In that case, reaching EOF means the
    /// message is complete.
    pub fn finishEof(self: *Self) void {
        if (self.state == .body and self.mode == .response and self.content_length == null and !self.chunked) {
            self.state = .complete;
        }
    }

    /// Feeds data to the parser, returning the number of bytes consumed.
    pub fn feed(self: *Self, data: []const u8) !usize {
        var consumed: usize = 0;

        while (consumed < data.len and self.state != .complete and self.state != .err) {
            const remaining = data[consumed..];
            consumed += switch (self.state) {
                .start => self.parseStart(remaining),
                .request_line => try self.parseRequestLine(remaining),
                .status_line => try self.parseStatusLine(remaining),
                .headers => try self.parseHeaders(remaining),
                .body => try self.parseBody(remaining),
                .chunk_size => try self.parseChunkSize(remaining),
                .chunk_data => try self.parseChunkData(remaining),
                .chunk_crlf => try self.parseChunkCrlf(remaining),
                .chunk_trailer => try self.parseChunkTrailer(remaining),
                .complete, .err => break,
            };
        }

        if (self.state == .complete) {}

        return consumed;
    }

    /// Returns true if parsing is complete.
    pub fn isComplete(self: *const Self) bool {
        return self.state == .complete;
    }

    /// Returns true if parsing encountered an error.
    pub fn isError(self: *const Self) bool {
        return self.state == .err;
    }

    /// Returns the parsed body.
    pub fn getBody(self: *const Self) []const u8 {
        return self.body_buffer.items;
    }

    /// Returns the parsed status.
    pub fn getStatus(self: *const Self) ?Status {
        if (self.status_code) |code| {
            return Status.fromCode(code);
        }
        return null;
    }

    /// Resets the parser for reuse.
    pub fn reset(self: *Self) void {
        self.state = .start;
        self.method = null;
        if (self.path) |p| {
            self.allocator.free(p);
            self.path = null;
        }
        self.status_code = null;
        self.headers.clear();
        self.body_buffer.clearRetainingCapacity();
        self.line_buffer.clearRetainingCapacity();
        self.content_length = null;
        self.chunked = false;
        self.current_chunk_size = 0;
        self.bytes_read = 0;
        self.chunk_crlf_read = 0;
        self.header_bytes = 0;
        self.header_count = 0;
        self.connection_close = false;
        self.connection_keep_alive = false;
        self.transfer_encoding_seen = false;
    }

    /// Returns whether the connection should be kept alive based on parsed headers
    /// and HTTP version. Implements RFC 7230 Section 6.3 semantics.
    pub fn isKeepAlive(self: *const Self) bool {
        if (self.connection_close) return false;
        if (self.connection_keep_alive) return true;
        // HTTP/1.1 defaults to keep-alive; HTTP/1.0 defaults to close.
        return self.version == .HTTP_1_1;
    }

    fn checkLineBufferLimit(self: *Self) !void {
        if (self.line_buffer.items.len > self.max_header_size) {
            self.state = .err;
            return error.HeaderTooLarge;
        }
    }

    fn bumpHeaderBytes(self: *Self, line_len: usize) !void {
        // Account for CRLF too.
        self.header_bytes += line_len + 2;
        if (self.header_bytes > self.max_header_size) {
            self.state = .err;
            return error.HeaderTooLarge;
        }
    }

    fn parseStart(self: *Self, data: []const u8) usize {
        if (data.len == 0) return 0;

        if (self.mode == .response) {
            self.state = .status_line;
        } else {
            self.state = .request_line;
        }
        return 0;
    }

    fn parseRequestLine(self: *Self, data: []const u8) !usize {
        const preceding_cr = self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r';
        const line = Line.init(data, .{ .allow_lf = self.compliance.allow_lf_in_fields, .preceding_cr = preceding_cr });
        if (line.ending == .none) {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        }
        if (preceding_cr and data.len > 0 and data[0] == '\n') {
            self.line_buffer.items.len -= 1;
        }

        const text = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, line.text());
            break :blk self.line_buffer.items;
        } else line.text();

        var parts = mem.splitScalar(u8, text, ' ');

        const method_str = parts.next() orelse {
            self.state = .err;
            return line.len;
        };
        self.method = types.Method.fromString(method_str) orelse .CUSTOM;

        const path = parts.next() orelse {
            self.state = .err;
            return line.len;
        };
        self.path = try self.allocator.dupe(u8, path);

        const version_str = parts.next() orelse {
            self.state = .err;
            return line.len;
        };
        self.version = types.Version.fromString(version_str) orelse .HTTP_1_1;

        try self.bumpHeaderBytes(text.len);

        self.line_buffer.clearRetainingCapacity();
        self.state = .headers;
        return line.len;
    }

    fn parseStatusLine(self: *Self, data: []const u8) !usize {
        const preceding_cr = self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r';
        const line = Line.init(data, .{ .allow_lf = self.compliance.allow_lf_in_fields, .preceding_cr = preceding_cr });
        if (line.ending == .none) {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        }
        if (preceding_cr and data.len > 0 and data[0] == '\n') {
            self.line_buffer.items.len -= 1;
        }

        const text = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, line.text());
            break :blk self.line_buffer.items;
        } else line.text();

        var parts = mem.splitScalar(u8, text, ' ');

        const version_str = parts.next() orelse {
            self.state = .err;
            return line.len;
        };
        self.version = types.Version.fromString(version_str) orelse .HTTP_1_1;

        const status_str = parts.next() orelse {
            self.state = .err;
            return line.len;
        };
        self.status_code = std.fmt.parseInt(u16, status_str, 10) catch {
            self.state = .err;
            return line.len;
        };

        try self.bumpHeaderBytes(text.len);

        self.line_buffer.clearRetainingCapacity();
        self.state = .headers;
        return line.len;
    }

    fn parseHeaders(self: *Self, data: []const u8) !usize {
        var lower_buf: [256]u8 = undefined; // For case-insensitive comparison buffers

        const preceding_cr = self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r';
        const line = Line.init(data, .{ .allow_lf = self.compliance.allow_lf_in_fields, .preceding_cr = preceding_cr });
        if (line.ending == .none) {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        }
        if (preceding_cr and data.len > 0 and data[0] == '\n') {
            self.line_buffer.items.len -= 1;
        }

        const text = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, line.text());
            break :blk self.line_buffer.items;
        } else line.text();

        if (text.len == 0) {
            self.line_buffer.clearRetainingCapacity();
            try self.bumpHeaderBytes(0);
            self.determineBodyState();
            return line.len;
        }

        try self.bumpHeaderBytes(text.len);

        if (mem.indexOf(u8, text, ":")) |sep| {
            if (self.header_count >= self.max_headers) {
                self.state = .err;
                return error.TooManyHeaders;
            }
            const name = mem.trim(u8, text[0..sep], " \t");
            const value = mem.trim(u8, text[sep + 1 ..], " \t");
            try self.headers.append(name, value);
            self.header_count += 1;

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                // RFC 7230 3.3.3: If Transfer-Encoding is present, Content-Length
                // must be silently ignored.
                if (self.transfer_encoding_seen) {
                    // Skip parsing this header entirely.
                } else {
                    // Content-Length may be a comma-separated list of integers,
                    // all of which must be identical.
                    var cl_iter = std.mem.splitScalar(u8, value, ',');
                    while (cl_iter.next()) |cl_part| {
                        const trimmed = std.mem.trim(u8, cl_part, " \t");
                        if (trimmed.len == 0) continue;
                        const cl = std.fmt.parseInt(u64, trimmed, 10) catch {
                            self.state = .err;
                            return error.InvalidContentLength;
                        };
                        if (self.content_length) |existing| {
                            if (existing != cl) {
                                // RFC 7230: conflicting Content-Length values are an error.
                                self.state = .err;
                                return error.InvalidContentLength;
                            }
                        } else {
                            self.content_length = cl;
                        }
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // RFC 7230 3.3.1: Transfer-Encoding is not allowed in HTTP/1.0.
                if (self.version == .HTTP_1_0) {
                    self.state = .err;
                    return error.InvalidChunkEncoding;
                }
                // RFC 7230 3.3.1: Only chunked is supported as the last transfer-coding.
                // Reject if "chunked" is not the last coding in the list.
                const lower_value = std.ascii.lowerString(&lower_buf, value);
                if (std.mem.lastIndexOf(u8, lower_value, "chunked")) |pos| {
                    // Check that nothing meaningful comes after "chunked"
                    const after = std.mem.trim(u8, lower_value[pos + 7 ..], " \t");
                    if (after.len > 0 and after[0] != ',') {
                        self.state = .err;
                        return error.InvalidChunkEncoding;
                    }
                    // Check that chunked is the LAST coding (no codings after the comma following chunked)
                    var coding_iter = std.mem.splitScalar(u8, lower_value, ',');
                    var last_was_chunked = false;
                    while (coding_iter.next()) |coding| {
                        const trimmed_coding = std.mem.trim(u8, coding, " \t");
                        if (std.mem.eql(u8, trimmed_coding, "chunked")) {
                            last_was_chunked = true;
                        } else if (last_was_chunked) {
                            // chunked is not the last coding
                            self.state = .err;
                            return error.InvalidChunkEncoding;
                        }
                    }
                    self.chunked = true;
                } else {
                    // Non-chunked Transfer-Encoding is not supported.
                    self.state = .err;
                    return error.InvalidChunkEncoding;
                }
                self.transfer_encoding_seen = true;
                if (self.content_length != null) {
                    // RFC 7230: Content-Length must be ignored when Transfer-Encoding
                    // is present. We clear it to avoid confusion.
                    self.content_length = null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.indexOfIgnoreCase(value, "close") != null) {
                    self.connection_close = true;
                }
                if (std.ascii.indexOfIgnoreCase(value, "keep-alive") != null) {
                    self.connection_keep_alive = true;
                }
            }
        }

        self.line_buffer.clearRetainingCapacity();
        return line.len;
    }

    fn noBodyByStatus(self: *const Self) bool {
        if (self.status_code) |code| {
            return (code >= 100 and code < 200) or code == 204 or code == 304;
        }
        return false;
    }

    fn determineBodyState(self: *Self) void {
        if (!self.expect_body or self.noBodyByStatus()) {
            self.state = .complete;
            return;
        }
        if (self.chunked) {
            self.state = .chunk_size;
        } else if (self.content_length) |len| {
            if (len > 0) {
                self.state = .body;
            } else {
                self.state = .complete;
            }
        } else if (self.mode == .response) {
            self.state = .body;
        } else {
            self.state = .complete;
        }
    }

    fn parseBody(self: *Self, data: []const u8) !usize {
        if (self.content_length) |len| {
            const remaining = len - self.bytes_read;
            const to_read = @min(data.len, @as(usize, @intCast(remaining)));
            // Enforce body size limit
            if (self.max_body_size > 0 and self.body_buffer.items.len + to_read > self.max_body_size) {
                self.state = .err;
                return error.BodyTooLarge;
            }
            try self.body_buffer.appendSlice(self.allocator, data[0..to_read]);
            self.bytes_read += to_read;

            if (self.bytes_read >= len) {
                self.state = .complete;
            }
            return to_read;
        }

        // EOF-delimited body: enforce body size limit
        if (self.max_body_size > 0 and self.body_buffer.items.len + data.len > self.max_body_size) {
            self.state = .err;
            return error.BodyTooLarge;
        }
        try self.body_buffer.appendSlice(self.allocator, data);
        return data.len;
    }

    fn parseChunkSize(self: *Self, data: []const u8) !usize {
        const preceding_cr = self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r';
        const line = Line.init(data, .{ .allow_lf = self.compliance.allow_lf_in_framing, .preceding_cr = preceding_cr });
        if (line.ending == .none) {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        }
        if (preceding_cr and data.len > 0 and data[0] == '\n') {
            self.line_buffer.items.len -= 1;
        }

        const text = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, line.text());
            break :blk self.line_buffer.items;
        } else line.text();

        const size_part = if (mem.indexOfScalar(u8, text, ';')) |semi|
            mem.trim(u8, text[0..semi], " \t")
        else
            mem.trim(u8, text, " \t");

        self.current_chunk_size = std.fmt.parseInt(usize, size_part, 16) catch {
            self.state = .err;
            return line.len;
        };

        self.line_buffer.clearRetainingCapacity();
        self.bytes_read = 0;
        self.chunk_crlf_read = 0;

        if (self.current_chunk_size == 0) {
            self.state = .chunk_trailer;
        } else {
            self.state = .chunk_data;
        }

        return line.len;
    }

    fn parseChunkData(self: *Self, data: []const u8) !usize {
        const remaining = self.current_chunk_size - self.bytes_read;
        const to_read = @min(data.len, remaining);

        // Enforce body size limit
        if (self.max_body_size > 0 and self.body_buffer.items.len + to_read > self.max_body_size) {
            self.state = .err;
            return error.BodyTooLarge;
        }

        try self.body_buffer.appendSlice(self.allocator, data[0..to_read]);
        self.bytes_read += to_read;

        if (self.bytes_read >= self.current_chunk_size) {
            self.state = .chunk_crlf;
        }

        return to_read;
    }

    fn parseChunkCrlf(self: *Self, data: []const u8) !usize {
        if (data.len == 0) return 0;

        var consumed: usize = 0;
        while (consumed < data.len and self.chunk_crlf_read < 2) {
            const b = data[consumed];
            switch (self.chunk_crlf_read) {
                0 => switch (b) {
                    '\r' => {},
                    '\n' => if (self.compliance.allow_lf_in_framing) {
                        self.chunk_crlf_read = 0;
                        self.state = .chunk_size;
                        return consumed + 1;
                    } else {
                        self.state = .err;
                        return error.InvalidChunkEncoding;
                    },
                    else => {
                        self.state = .err;
                        return error.InvalidChunkEncoding;
                    },
                },
                1 => if (b != '\n') {
                    self.state = .err;
                    return error.InvalidChunkEncoding;
                },
                else => {},
            }
            self.chunk_crlf_read += 1;
            consumed += 1;
        }

        if (self.chunk_crlf_read == 2) {
            self.chunk_crlf_read = 0;
            self.state = .chunk_size;
        }

        return consumed;
    }

    fn parseChunkTrailer(self: *Self, data: []const u8) !usize {
        const preceding_cr = self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r';
        const line = Line.init(data, .{ .allow_lf = self.compliance.allow_lf_in_framing, .preceding_cr = preceding_cr });
        if (line.ending == .none) {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        }
        if (preceding_cr and data.len > 0 and data[0] == '\n') {
            self.line_buffer.items.len -= 1;
        }

        const text = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, line.text());
            break :blk self.line_buffer.items;
        } else line.text();

        // Ignore trailer fields but consume them until the terminating empty line.
        if (text.len == 0) {
            self.line_buffer.clearRetainingCapacity();
            self.state = .complete;
            return line.len;
        }

        self.line_buffer.clearRetainingCapacity();
        return line.len;
    }
};

/// Detects CL/TE ambiguity which can lead to HTTP request smuggling.
/// Returns true if both Content-Length and Transfer-Encoding are present,
/// indicating a potential smuggling vector.
pub fn detectClTeAmbiguity(content_length: ?u64, transfer_encoding: ?[]const u8) bool {
    if (content_length != null and transfer_encoding != null) {
        return true;
    }
    return false;
}

test "detectClTeAmbiguity" {
    // Both present -> ambiguous
    try std.testing.expect(detectClTeAmbiguity(100, "chunked"));
    // Only CL -> not ambiguous
    try std.testing.expect(!detectClTeAmbiguity(100, null));
    // Only TE -> not ambiguous
    try std.testing.expect(!detectClTeAmbiguity(null, "chunked"));
    // Neither -> not ambiguous
    try std.testing.expect(!detectClTeAmbiguity(null, null));
}

test "Parser request line" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    const data = "GET /api/users HTTP/1.1\r\nHost: httpbun.com\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(types.Method.GET, parser.method.?);
    try std.testing.expectEqualStrings("/api/users", parser.path.?);
}

test "Parser response" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(?u16, 200), parser.status_code);
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser chunked encoding" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser response body by close (finishEof)" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\n\r\nHello";
    _ = try parser.feed(data);
    try std.testing.expect(!parser.isComplete());
    parser.finishEof();
    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser chunked with extension and split CRLF" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    _ = try parser.feed("5;foo=bar\r\nHel");
    _ = try parser.feed("lo\r");
    _ = try parser.feed("\n0\r\n\r\n");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser headers" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    const data = "GET / HTTP/1.1\r\nHost: httpbun.com\r\nUser-Agent: test\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expectEqualStrings("httpbun.com", parser.headers.get("Host").?);
    try std.testing.expectEqualStrings("test", parser.headers.get("User-Agent").?);
}

test "Parser reset" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    _ = try parser.feed("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(parser.isComplete());

    parser.reset();
    try std.testing.expect(!parser.isComplete());
    try std.testing.expect(parser.method == null);
}

test "Parser Content-Length comma-separated list (identical values)" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // RFC 7230 3.3.3 errata: comma-separated Content-Length values that are identical
    const data = "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\n\r\nHello";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(?u64, 5), parser.content_length);
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser Content-Length comma-separated list (conflicting values)" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // RFC 7230 3.3.3: conflicting Content-Length values must be rejected.
    const data = "HTTP/1.1 200 OK\r\nContent-Length: 5, 10\r\n\r\nHello";
    const result = parser.feed(data);

    try std.testing.expectError(error.InvalidContentLength, result);
}

test "Parser Transfer-Encoding on HTTP/1.0 is rejected" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // RFC 7230 3.3.1: Transfer-Encoding is not allowed in HTTP/1.0.
    const data = "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    const result = parser.feed(data);

    try std.testing.expectError(error.InvalidChunkEncoding, result);
}

test "Parser Transfer-Encoding non-chunked is rejected" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // Non-chunked Transfer-Encoding (e.g., gzip) is not supported.
    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n";
    const result = parser.feed(data);

    try std.testing.expectError(error.InvalidChunkEncoding, result);
}

test "Parser Transfer-Encoding not last coding is rejected" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // chunked must be the last transfer coding
    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n";
    const result = parser.feed(data);

    try std.testing.expectError(error.InvalidChunkEncoding, result);
}

test "Parser Content-Length ignored when Transfer-Encoding present" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // When Transfer-Encoding is present, Content-Length must be ignored per RFC 7230.
    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 999\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    // Content-Length should be cleared
    try std.testing.expect(parser.content_length == null);
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser Connection header tracking" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expect(parser.connection_close);
    try std.testing.expect(!parser.isKeepAlive());
}

test "Parser HTTP/1.1 default keep-alive" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expect(parser.isKeepAlive());
}

test "Parser HTTP/1.0 default close" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expect(!parser.isKeepAlive());
}

test "Parser HTTP/1.0 with Connection: keep-alive" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expect(parser.connection_keep_alive);
    try std.testing.expect(parser.isKeepAlive());
}

test "Parser body size limit exceeded" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();
    parser.max_body_size = 5; // Only allow 5 bytes

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789";
    const result = parser.feed(data);

    try std.testing.expectError(error.BodyTooLarge, result);
}

test "Parser body size limit chunked" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();
    parser.max_body_size = 3; // Only allow 3 bytes

    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    const result = parser.feed(data);

    try std.testing.expectError(error.BodyTooLarge, result);
}

test "Parser body size limit 0 means unlimited" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();
    parser.max_body_size = 0; // Unlimited

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("0123456789", parser.getBody());
}

test "Parser reset clears new fields" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expect(parser.connection_close);

    parser.reset();
    try std.testing.expect(!parser.connection_close);
    try std.testing.expect(!parser.connection_keep_alive);
    try std.testing.expect(!parser.transfer_encoding_seen);
}

test "Parser case-insensitive Content-Length" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nHello";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(?u64, 5), parser.content_length);
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser multiple Content-Length with spaces" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    // With spaces around the comma
    const data = "HTTP/1.1 200 OK\r\nContent-Length: 5 , 5\r\n\r\nHello";
    _ = try parser.feed(data);

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(?u64, 5), parser.content_length);
}

test "Parser LF field terminators rejected when strict" {
    // Same as unchanged code: strict mode treats a lone LF as no terminator.
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\nContent-Length: 5\n\nHello");

    try std.testing.expect(!parser.isComplete());
    try std.testing.expect(!parser.isError());
}

test "Parser LF field terminators accepted with allow_lf_in_fields" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    parser.compliance.allow_lf_in_fields = true;
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\nContent-Length: 5\n\nHello");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(?u16, 200), parser.status_code);
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser CRLF field terminators still parse with allow_lf_in_fields" {
    // Same as unchanged code: CRLF is parsed regardless of the flag.
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    parser.compliance.allow_lf_in_fields = true;
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser CRLF split across feeds keeps fields separate" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    _ = try parser.feed("GET / HTTP/1.1\r\nHost: x\r");
    _ = try parser.feed("\nAccept: y\r\n\r\n");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("x", parser.headers.get("Host").?);
    try std.testing.expectEqualStrings("y", parser.headers.get("Accept").?);
}

test "Parser LF followed by CR is rejected under both modes" {
    const allocator = std.testing.allocator;
    const data = "GET / HTTP/1.1\r\nX: a\n\rY: b\r\n\r\n";

    // Strict mode is unchanged: the LF is not a terminator, so the trailing
    // bytes fold into X's value, which is rejected as an invalid value.
    var strict = Parser.init(allocator);
    defer strict.deinit();
    try std.testing.expectError(error.InvalidHeaderValue, strict.feed(data));

    // Lenient mode: the LF ends X and the following CR becomes the first byte
    // of the next field name, which is rejected as an invalid name.
    var lenient = Parser.init(allocator);
    lenient.compliance.allow_lf_in_fields = true;
    defer lenient.deinit();
    try std.testing.expectError(error.InvalidHeaderName, lenient.feed(data));
}

test "Parser lone CR never terminates a field" {
    // Same as unchanged code: a lone CR is not a line terminator.
    const allocator = std.testing.allocator;

    var strict = Parser.init(allocator);
    defer strict.deinit();
    _ = try strict.feed("GET / HTTP/1.1\rHost: x\r\r");
    try std.testing.expect(!strict.isComplete());

    var lenient = Parser.init(allocator);
    lenient.compliance.allow_lf_in_fields = true;
    defer lenient.deinit();
    _ = try lenient.feed("GET / HTTP/1.1\rHost: x\r\r");
    try std.testing.expect(!lenient.isComplete());
}

test "Parser LF chunk framing accepted with allow_lf_in_framing" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    parser.compliance.allow_lf_in_framing = true;
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\nHello\n0\n\n");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}

test "Parser LF chunk framing rejected without the framing flag" {
    // Same as unchanged code: LF framing is rejected without allow_lf_in_framing.
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    parser.compliance.allow_lf_in_fields = true;
    defer parser.deinit();

    const data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\n0\r\n\r\n";
    try std.testing.expectError(error.InvalidChunkEncoding, parser.feed(data));
}

test "Parser CRLF split across feeds in chunk size line" {
    const allocator = std.testing.allocator;
    var parser = Parser.initResponse(allocator);
    defer parser.deinit();

    _ = try parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r");
    _ = try parser.feed("\nHello\r\n0\r\n\r\n");

    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqualStrings("Hello", parser.getBody());
}
