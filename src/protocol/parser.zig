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

    const Self = @This();

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
        const line_end = mem.indexOf(u8, data, "\r\n") orelse {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        };

        const line = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, data[0..line_end]);
            break :blk self.line_buffer.items;
        } else data[0..line_end];

        var parts = mem.splitScalar(u8, line, ' ');

        const method_str = parts.next() orelse {
            self.state = .err;
            return line_end + 2;
        };
        self.method = types.Method.fromString(method_str) orelse .CUSTOM;

        const path = parts.next() orelse {
            self.state = .err;
            return line_end + 2;
        };
        self.path = try self.allocator.dupe(u8, path);

        const version_str = parts.next() orelse {
            self.state = .err;
            return line_end + 2;
        };
        self.version = types.Version.fromString(version_str) orelse .HTTP_1_1;

        try self.bumpHeaderBytes(line.len);

        self.line_buffer.clearRetainingCapacity();
        self.state = .headers;
        return line_end + 2;
    }

    fn parseStatusLine(self: *Self, data: []const u8) !usize {
        const line_end = mem.indexOf(u8, data, "\r\n") orelse {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        };

        const line = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, data[0..line_end]);
            break :blk self.line_buffer.items;
        } else data[0..line_end];

        var parts = mem.splitScalar(u8, line, ' ');

        const version_str = parts.next() orelse {
            self.state = .err;
            return line_end + 2;
        };
        self.version = types.Version.fromString(version_str) orelse .HTTP_1_1;

        const status_str = parts.next() orelse {
            self.state = .err;
            return line_end + 2;
        };
        self.status_code = std.fmt.parseInt(u16, status_str, 10) catch {
            self.state = .err;
            return line_end + 2;
        };

        try self.bumpHeaderBytes(line.len);

        self.line_buffer.clearRetainingCapacity();
        self.state = .headers;
        return line_end + 2;
    }

    fn parseHeaders(self: *Self, data: []const u8) !usize {
        const line_end = mem.indexOf(u8, data, "\r\n") orelse {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        };

        const line = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, data[0..line_end]);
            break :blk self.line_buffer.items;
        } else data[0..line_end];

        if (line.len == 0) {
            self.line_buffer.clearRetainingCapacity();
            try self.bumpHeaderBytes(0);
            self.determineBodyState();
            return line_end + 2;
        }

        try self.bumpHeaderBytes(line.len);

        if (mem.indexOf(u8, line, ":")) |sep| {
            if (self.header_count >= self.max_headers) {
                self.state = .err;
                return error.TooManyHeaders;
            }
            const name = mem.trim(u8, line[0..sep], " \t");
            const value = mem.trim(u8, line[sep + 1 ..], " \t");
            try self.headers.append(name, value);
            self.header_count += 1;

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                self.content_length = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (mem.indexOf(u8, value, "chunked") != null) {
                    self.chunked = true;
                }
            }
        }

        self.line_buffer.clearRetainingCapacity();
        return line_end + 2;
    }

    fn determineBodyState(self: *Self) void {
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
            try self.body_buffer.appendSlice(self.allocator, data[0..to_read]);
            self.bytes_read += to_read;

            if (self.bytes_read >= len) {
                self.state = .complete;
            }
            return to_read;
        }

        try self.body_buffer.appendSlice(self.allocator, data);
        return data.len;
    }

    fn parseChunkSize(self: *Self, data: []const u8) !usize {
        const line_end = mem.indexOf(u8, data, "\r\n") orelse {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        };

        const line = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, data[0..line_end]);
            break :blk self.line_buffer.items;
        } else data[0..line_end];

        const size_part = if (mem.indexOfScalar(u8, line, ';')) |semi|
            mem.trim(u8, line[0..semi], " \t")
        else
            mem.trim(u8, line, " \t");

        self.current_chunk_size = std.fmt.parseInt(usize, size_part, 16) catch {
            self.state = .err;
            return line_end + 2;
        };

        self.line_buffer.clearRetainingCapacity();
        self.bytes_read = 0;
        self.chunk_crlf_read = 0;

        if (self.current_chunk_size == 0) {
            self.state = .chunk_trailer;
        } else {
            self.state = .chunk_data;
        }

        return line_end + 2;
    }

    fn parseChunkData(self: *Self, data: []const u8) !usize {
        const remaining = self.current_chunk_size - self.bytes_read;
        const to_read = @min(data.len, remaining);

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
                0 => if (b != '\r') {
                    self.state = .err;
                    return error.InvalidChunkEncoding;
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
        const line_end = mem.indexOf(u8, data, "\r\n") orelse {
            try self.line_buffer.appendSlice(self.allocator, data);
            try self.checkLineBufferLimit();
            return data.len;
        };

        const line = if (self.line_buffer.items.len > 0) blk: {
            try self.line_buffer.appendSlice(self.allocator, data[0..line_end]);
            break :blk self.line_buffer.items;
        } else data[0..line_end];

        // Ignore trailer fields but consume them until the terminating empty line.
        if (line.len == 0) {
            self.line_buffer.clearRetainingCapacity();
            self.state = .complete;
            return line_end + 2;
        }

        self.line_buffer.clearRetainingCapacity();
        return line_end + 2;
    }
};

test "Parser request line" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    const data = "GET /api/users HTTP/1.1\r\nHost: example.com\r\n\r\n";
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

    const data = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: test\r\n\r\n";
    _ = try parser.feed(data);

    try std.testing.expectEqualStrings("example.com", parser.headers.get("Host").?);
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
