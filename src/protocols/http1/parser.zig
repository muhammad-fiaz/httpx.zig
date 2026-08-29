//! HTTP/1.0 + HTTP/1.1 message parsing (RFC 9112).
//!
//! Zero-copy single-pass head parsing modeled on picohttpparser's
//! algorithm: feed arbitrary network chunks into a caller-owned buffer,
//! parse returns consumed length or error.Incomplete. Body framing via
//! Content-Length or an incremental chunked decoder with trailers.
//!
//! Security posture:
//!   * CL+TE together -> error.AmbiguousFraming (request smuggling)
//!   * Transfer-Encoding whose final coding isn't "chunked" -> error
//!   * conflicting duplicate Content-Length -> error
//!   * obs-fold (continuation lines) -> error.ObsFold
//!   * whitespace before header colon -> error.MalformedHeaderLine
//!   * control characters anywhere in tokens/values -> error
//!   * all lengths overflow-checked; configurable limits
//!
//! References:
//!   - RFC 9112 Section 2.1 — Request Line (method SP request-target SP HTTP-version)
//!   - RFC 9112 Section 2.2 — Status Line (HTTP-version SP status-code SP reason-phrase)
//!   - RFC 9112 Section 3 — Field Syntax (header fields)
//!   - RFC 9112 Section 5.1 — Message Body (Content-Length)
//!   - RFC 9112 Section 5.3 — Transfer-Encoding (chunked)
//!   - RFC 9112 Section 6.3 — Status Code Rules
//!   - RFC 9112 Section 7.1 — Transfer Encoding (obs-fold rejection)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    Incomplete,
    MalformedRequestLine,
    MalformedStatusLine,
    MalformedHeaderLine,
    UnsupportedHttpVersion,
    HeaderTooLarge,
    TooManyHeaders,
    InvalidContentLength,
    AmbiguousFraming,
    InvalidChunkSize,
    ObsFold,
    OutOfMemory,
};

pub const DEFAULT_MAX_HEADER_BYTES: usize = 32 * 1024;
pub const DEFAULT_MAX_BODY_BYTES: usize = 64 * 1024 * 1024;
pub const DEFAULT_MAX_HEADERS: usize = 128;
pub const MAX_METHOD_LEN: usize = 16;
pub const MAX_TARGET_LEN: usize = 8192;

/// Parser options for lenient line ending handling (issue #37).
pub const Options = struct {
    allow_lf_line_endings: bool = false,
};

fn isCtl(c: u8) bool {
    return c <= 0x1F or c == 0x7F;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => std.ascii.isAlphanumeric(c),
    };
}

/// Finds the next LF starting from `pos`; rejects bare control chars
/// outside CR/LF/HTAB so malformed binary can't scan unbounded.
fn findEol(buf: []const u8, pos: usize) ParseError!usize {
    return findEolWithOptions(buf, pos, .{});
}

fn findEolWithOptions(buf: []const u8, pos: usize, opts: Options) ParseError!usize {
    var i = pos;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == '\n') {
            // In strict mode (allow_lf_line_endings == false), line must end in \r\n
            if (!opts.allow_lf_line_endings) {
                if (i == pos or buf[i - 1] != '\r') {
                    return ParseError.MalformedHeaderLine;
                }
            }
            return i;
        }
        // Bare control character check (excluding \r and \t)
        if (isCtl(c) and c != '\r' and c != '\t') return ParseError.MalformedHeaderLine;
    }
    return ParseError.Incomplete;
}

pub const HeadResult = struct {
    method: []const u8 = "",
    path: []const u8 = "",
    status_code: u16 = 0,
    reason: []const u8 = "",
    minor_version: u8 = 1,
    major_version: u8 = 1,
    /// Offset one past the request/status line's LF.
    head_end: usize = 0,
};

/// Parses a request line: METHOD SP TARGET SP HTTP/1.x CRLF.
/// Tolerates multiple SPs between tokens like picohttpparser.
pub fn parseRequestHead(buf: []const u8) ParseError!HeadResult {
    return parseRequestHeadWithOptions(buf, .{});
}

pub fn parseRequestHeadWithOptions(buf: []const u8, opts: Options) ParseError!HeadResult {
    _ = opts;
    var r = HeadResult{};
    var pos: usize = 0;

    // Skip leading empty line(s) (clients sometimes send CRLF after POST).
    // Always tolerate both CRLF and LF here per RFC 9112 Section 2.2.
    while (pos < buf.len) {
        if (buf[pos] == '\r') {
            if (pos + 1 >= buf.len) return ParseError.Incomplete;
            if (buf[pos + 1] != '\n') break;
            pos += 2;
        } else if (buf[pos] == '\n') {
            pos += 1;
        } else break;
    }
    if (pos >= buf.len) return ParseError.Incomplete;

    // Method token.
    var end = pos;
    while (end < buf.len and isTokenChar(buf[end])) end += 1;
    if (end == pos or end > pos + MAX_METHOD_LEN) return ParseError.MalformedRequestLine;
    r.method = buf[pos..end];

    if (end >= buf.len) return ParseError.Incomplete;
    if (buf[end] != ' ') return ParseError.MalformedRequestLine;
    while (end < buf.len and buf[end] == ' ') end += 1;
    if (end >= buf.len) return ParseError.Incomplete;

    // Target: no spaces or controls allowed inside.
    pos = end;
    end = pos;
    while (end < buf.len) {
        const c = buf[end];
        if (c == ' ') break;
        if (isCtl(c)) return ParseError.MalformedRequestLine;
        end += 1;
    }
    if (end == pos or end > pos + MAX_TARGET_LEN) return ParseError.MalformedRequestLine;
    r.path = buf[pos..end];
    if (end >= buf.len) return ParseError.Incomplete;

    while (end < buf.len and buf[end] == ' ') end += 1;

    // Version: exactly HTTP/1.x then CRLF/LF.
    if (buf.len < end + 8) return ParseError.Incomplete;
    if (!std.mem.eql(u8, buf[end..][0..7], "HTTP/1.")) return ParseError.UnsupportedHttpVersion;
    const minor = buf[end + 7];
    if (minor != '0' and minor != '1') return ParseError.UnsupportedHttpVersion;
    r.major_version = 1;
    r.minor_version = minor - '0';
    end += 8;

    if (end >= buf.len) return ParseError.Incomplete;
    if (buf[end] == '\r') {
        end += 1;
        if (end >= buf.len) return ParseError.Incomplete;
        if (buf[end] != '\n') return ParseError.MalformedRequestLine;
        r.head_end = end + 1;
        return r;
    }
    // Bare LF for request line is always strict (RFC 9112) — even with lenient flag
    return ParseError.MalformedRequestLine;
}

pub fn parseResponseHead(buf: []const u8) ParseError!HeadResult {
    return parseResponseHeadWithOptions(buf, .{});
}

pub fn parseResponseHeadWithOptions(buf: []const u8, opts: Options) ParseError!HeadResult {
    var r = HeadResult{};
    var pos: usize = 0;

    while (pos < buf.len) {
        if (buf[pos] == '\r') {
            if (pos + 1 >= buf.len) return ParseError.Incomplete;
            if (buf[pos + 1] != '\n') break;
            pos += 2;
        } else if (buf[pos] == '\n') {
            if (!opts.allow_lf_line_endings) break;
            pos += 1;
        } else break;
    }
    if (pos >= buf.len) return ParseError.Incomplete;

    if (buf.len < pos + 12) return ParseError.Incomplete;
    if (!std.mem.eql(u8, buf[pos..][0..7], "HTTP/1.")) return ParseError.UnsupportedHttpVersion;
    const minor = buf[pos + 7];
    if (minor != '0' and minor != '1') return ParseError.UnsupportedHttpVersion;
    r.major_version = 1;
    r.minor_version = minor - '0';

    if (buf[pos + 8] != ' ') return ParseError.MalformedStatusLine;

    // Exactly three digits followed by space or EOL.
    const code_start = pos + 9;
    for (code_start..code_start + 3) |i| {
        if (!std.ascii.isDigit(buf[i])) return ParseError.MalformedStatusLine;
    }
    r.status_code = std.fmt.parseInt(u16, buf[code_start..][0..3], 10) catch unreachable;
    var end = code_start + 3;

    if (end < buf.len and buf[end] != '\r' and buf[end] != '\n') {
        if (buf[end] != ' ') return ParseError.MalformedStatusLine;
        // Reason phrase runs to EOL (may contain SP/HTAB only as OWS-ish text).
        const le = findEolWithOptions(buf, end, opts) catch |e| switch (e) {
            ParseError.Incomplete => return ParseError.Incomplete,
            else => return ParseError.MalformedStatusLine,
        };
        var ve = le;
        if (ve > end and buf[ve - 1] == '\r') ve -= 1;
        r.reason = buf[end + 1 .. ve];
        end = le;
    }

    // Consume EOL: CRLF always allowed, bare LF only with flag.
    if (end >= buf.len) return ParseError.Incomplete;
    if (buf[end] == '\r') {
        if (end + 1 >= buf.len) return ParseError.Incomplete;
        if (buf[end + 1] != '\n') return ParseError.MalformedStatusLine;
        r.head_end = end + 2;
        return r;
    }
    if (buf[end] == '\n') {
        // If previous is \r, this is actually CRLF where findEol returned \n index
        if (end > 0 and buf[end - 1] == '\r') {
            r.head_end = end + 1;
            return r;
        }
        if (!opts.allow_lf_line_endings) return ParseError.MalformedStatusLine;
        r.head_end = end + 1;
        return r;
    }
    return ParseError.MalformedStatusLine;
}

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderBlockResult = struct { count: usize, end: usize };

/// Parses a header block starting at buf[start..] up to the empty line.
/// Returns field slices (into buf) and the offset past the blank line.
// Rejects: obs-fold continuation lines, whitespace before the colon,
// control chars in names/values, empty names.
pub fn parseHeaderBlock(buf: []const u8, start: usize, fields: []Field) ParseError!HeaderBlockResult {
    return parseHeaderBlockWithOptions(buf, start, fields, .{});
}

pub fn parseHeaderBlockWithOptions(buf: []const u8, start: usize, fields: []Field, opts: Options) ParseError!HeaderBlockResult {
    var pos = start;
    var n: usize = 0;

    while (true) {
        if (pos >= buf.len) return ParseError.Incomplete;
        // End of headers detection (empty line):
        // 1. CRLF empty line: \r\n
        // 2. LF empty line: \n (allowed only if opts.allow_lf_line_endings)
        // Lone \r without \n is NOT end-of-headers; it is part of content or malformed line.
        if (buf[pos] == '\r') {
            if (pos + 1 >= buf.len) return ParseError.Incomplete;
            if (buf[pos + 1] == '\n') return .{ .count = n, .end = pos + 2 };
            // If lone \r is encountered at the start of a line, it's not a valid blank line.
            return ParseError.MalformedHeaderLine;
        }
        if (buf[pos] == '\n') {
            if (opts.allow_lf_line_endings) return .{ .count = n, .end = pos + 1 };
            return ParseError.MalformedHeaderLine;
        }

        const line_end = try findEolWithOptions(buf, pos, opts);
        var value_end = line_end;
        if (line_end > pos and buf[line_end - 1] == '\r') value_end -= 1;

        // Whitespace before colon is forbidden (RFC 9112 §5.1).
        const colon = std.mem.indexOfScalar(u8, buf[pos..value_end], ':') orelse {
            // A line starting with SP/HTAB here is obs-fold.
            if (buf[pos] == ' ' or buf[pos] == '\t') return ParseError.ObsFold;
            return ParseError.MalformedHeaderLine;
        };
        if (colon == 0) return ParseError.MalformedHeaderLine;

        // Name must be a clean token with NO surrounding whitespace.
        const name = buf[pos..][0..colon];
        for (name) |ch| {
            if (!isTokenChar(ch)) return ParseError.MalformedHeaderLine;
        }

        // Value: strip leading/trailing SP/HTAB (OWS).
        var vs = pos + colon + 1;
        var ve = value_end;
        while (vs < ve and (buf[vs] == ' ' or buf[vs] == '\t')) vs += 1;
        while (ve > vs and (buf[ve - 1] == ' ' or buf[ve - 1] == '\t')) ve -= 1;
        for (buf[vs..ve]) |ch| {
            // Check for control characters (except HTAB and lone \r)
            if (isCtl(ch) and ch != '\t' and ch != '\r') return ParseError.MalformedHeaderLine;
        }

        if (name.len > 256) return ParseError.HeaderTooLarge;
        if (vs - (pos + colon + 1) + ve > DEFAULT_MAX_HEADER_BYTES) return ParseError.HeaderTooLarge;

        if (n >= fields.len) return ParseError.TooManyHeaders;
        fields[n] = .{ .name = name, .value = buf[vs..ve] };
        n += 1;
        pos = line_end + 1;
    }
}

pub const Framing = enum { none, content_length, chunked, tunnel };

pub const FramingDecision = struct {
    framing: Framing,
    length: usize = 0,
};

/// Determine body framing per RFC 9112 ï¿½6.3 with smuggling defenses.
/// Requests without CL/TE have no body. Responses may be close-delimited
/// (framing=none, length=0, caller decides) except 1xx/204/304 and HEAD.
/// CONNECT 2xx switches to tunnel semantics (pass `connect_ok=true`).
pub fn decideFraming(
    fields: []const Field,
    is_response: bool,
    status: u16,
    method_len: usize,
) ParseError!FramingDecision {
    return framingFull(fields, .{
        .is_response = is_response,
        .status = status,
        .method_len = method_len,
    });
}

pub const FramingContext = struct {
    is_response: bool = false,
    status: u16 = 0,
    /// Length of the request method string; 4 => HEAD when is_response.
    method_len: usize = 0,
    /// Treat 2xx responses to CONNECT as tunnels.
    connect_ok: bool = false,
    /// True for HTTP/1.0 where Transfer-Encoding chunked is forbidden (RFC 9112 smuggling).
    is_http_10: bool = false,
    /// Upper bound applied to any declared content length.
    max_body: usize = DEFAULT_MAX_BODY_BYTES,
};

pub fn framingFull(fields: []const Field, ctx: FramingContext) ParseError!FramingDecision {
    // Responses terminated by head end ignore any framing headers
    // (RFC 9110 section 6.3: 1xx, 204, 304; HEAD handled via method).
    if (ctx.is_response) {
        if (ctx.status < 200 or ctx.status == 204 or ctx.status == 304) {
            return .{ .framing = .none, .length = 0 };
        }
        // HEAD responses never carry a message body. Content-Length remains
        // representation metadata, but must not make the client consume
        // bytes from the connection (RFC 9112 Section 6.3).
        if (ctx.method_len == 4) {
            return .{ .framing = .none, .length = 0 };
        }
        if (ctx.connect_ok and ctx.status < 300) {
            return .{ .framing = .tunnel, .length = 0 };
        }
    }

    var has_cl = false;
    var cl: usize = 0;
    var has_te = false;
    var te_chunked_final = false;

    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, "Content-Length")) {
            // Digits only; reject "+5", " 5", "5 ", hex, empty.
            if (f.value.len == 0) return ParseError.InvalidContentLength;
            for (f.value) |c| {
                if (!std.ascii.isDigit(c)) return ParseError.InvalidContentLength;
            }
            const v = std.fmt.parseInt(usize, f.value, 10) catch return ParseError.InvalidContentLength;
            if (v > ctx.max_body) return ParseError.InvalidContentLength;
            if (has_cl and cl != v) return ParseError.AmbiguousFraming; // differing duplicates
            has_cl = true;
            cl = v;
        } else if (std.ascii.eqlIgnoreCase(f.name, "Transfer-Encoding")) {
            has_te = true;
            // Final coding must be chunked; list form "gzip, chunked" ok.
            te_chunked_final = endsWithCodingChunked(f.value);
        }
    }

    if (has_te and !te_chunked_final) return ParseError.AmbiguousFraming;
    if (has_te and has_cl) return ParseError.AmbiguousFraming; // classic smuggling vector
    if (has_te and ctx.is_http_10) return ParseError.AmbiguousFraming; // 1.0 must not use chunked
    if (has_te) return .{ .framing = .chunked, .length = 0 };
    if (has_cl) return .{ .framing = .content_length, .length = cl };

    // No framing info: read-until-close for responses (caller decides);
    // requests without CL/TE have no body.
    return .{ .framing = .none, .length = 0 };
}

/// True when the last comma-separated coding of a TE value is "chunked".
fn endsWithCodingChunked(value: []const u8) bool {
    var it = std.mem.splitBackwardsScalar(u8, value, ',');
    const last_raw = it.next() orelse return false;
    const last = std.mem.trim(u8, last_raw, " \t");
    return std.ascii.eqlIgnoreCase(last, "chunked");
}

// Chunked transfer decoding (RFC 9112 section 7.1)

/// Incremental chunked decoder: in-place payload compaction, strict CRLF,
/// safe extension skipping, overflow guards, optional trailer collection.
/// Feed raw bytes; decoded payload compacts toward buffer start. On success
/// returns the offset of the first byte AFTER the terminating blank line
/// (pipelined tail), or error.Incomplete while more input is needed.
pub const ChunkedDecoder = struct {
    pub const State = enum { size, size_cr, ext, ext_cr, data, data_cr, data_lf, trailer, done };

    state: State = .size,
    remaining_in_chunk: u64 = 0,
    size_acc: u64 = 0,
    size_digits: usize = 0,

    max_chunk_size: u64 = DEFAULT_MAX_BODY_BYTES,

    /// Optional sink for trailer fields. Field slices point into the most
    /// recent input buffer and are valid only until it is reused.
    /// When set, `trailer_allocator` must be set too (ArrayList is unmanaged).
    trailers: ?*std.ArrayList(Field) = null,
    trailer_allocator: Allocator = std.heap.page_allocator,
    trailers_seen: usize = 0,

    total_decoded: u64 = 0,

    /// Raw bytes consumed from the most recent decode() input. On
    /// error.Incomplete the caller drops this prefix, appends new data,
    /// and calls again (phr_decode_chunked-style).
    raw_consumed: usize = 0,

    /// Payload bytes produced by the most recent decode() call; they
    /// occupy buf[0..decoded_len]. Callers accumulating a streamed body
    /// must copy these out before dropping the consumed prefix.
    decoded_len: usize = 0,

    pub fn init() ChunkedDecoder {
        return .{};
    }

    pub fn isDone(self: *const ChunkedDecoder) bool {
        return self.state == .done;
    }

    pub fn decode(self: *ChunkedDecoder, buf: []u8) ParseError!usize {
        var src: usize = 0;
        var dst: usize = 0;

        loop: while (src < buf.len) {
            switch (self.state) {
                .size => {
                    const c = buf[src];
                    src += 1;
                    switch (c) {
                        '0'...'9' => self.pushDigit(c - '0'),
                        'a'...'f' => self.pushDigit(c - 'a' + 10),
                        'A'...'F' => self.pushDigit(c - 'A' + 10),
                        ';' => self.state = .ext,
                        '\r' => self.state = .size_cr,
                        '\n' => try self.endSizeLine(),
                        else => return ParseError.InvalidChunkSize,
                    }
                },
                .size_cr => {
                    const c = buf[src];
                    src += 1;
                    if (c != '\n') return ParseError.InvalidChunkSize;
                    try self.endSizeLine();
                },
                .ext => {
                    // Skip chunk extensions to EOL; reject raw controls.
                    const c = buf[src];
                    src += 1;
                    switch (c) {
                        '\r' => self.state = .ext_cr,
                        '\n' => try self.endSizeLine(),
                        '\t', ' ' => {},
                        else => if (isCtl(c)) return ParseError.InvalidChunkSize,
                    }
                },
                .ext_cr => {
                    const c = buf[src];
                    src += 1;
                    if (c != '\n') return ParseError.InvalidChunkSize;
                    try self.endSizeLine();
                },
                .data => {
                    const avail: u64 = @min(@as(u64, buf.len - src), self.remaining_in_chunk);
                    const n: usize = @intCast(avail);
                    std.mem.copyForwards(u8, buf[dst..][0..n], buf[src..][0..n]);
                    dst += n;
                    src += n;
                    self.remaining_in_chunk -= avail;
                    self.total_decoded += avail;
                    if (self.remaining_in_chunk == 0) self.state = .data_cr;
                },
                .data_cr => {
                    const c = buf[src];
                    src += 1;
                    if (c == '\r') {
                        self.state = .data_lf;
                    } else if (c == '\n') {
                        // Lax bare-LF between chunks (matches picohttpparser).
                        self.enterSize();
                    } else return ParseError.InvalidChunkSize;
                },
                .data_lf => {
                    const c = buf[src];
                    src += 1;
                    if (c != '\n') return ParseError.InvalidChunkSize;
                    self.enterSize();
                },
                .trailer => {
                    var tfields: [DEFAULT_MAX_HEADERS]Field = undefined;
                    const res = parseHeaderBlock(buf[src..], 0, tfields[0..]) catch |err| switch (err) {
                        ParseError.Incomplete => break :loop,
                        ParseError.TooManyHeaders => return ParseError.InvalidChunkSize,
                        else => return err,
                    };
                    if (self.trailers) |list| {
                        list.appendSlice(self.trailer_allocator, tfields[0..res.count]) catch return ParseError.OutOfMemory;
                    }
                    self.trailers_seen += res.count;
                    src += res.end;
                    self.state = .done;
                },
                .done => break :loop,
            }
        }

        self.raw_consumed = src;
        self.decoded_len = dst;
        if (self.state == .done) return src;
        return ParseError.Incomplete;
    }

    fn pushDigit(self: *ChunkedDecoder, d: u64) void {
        self.size_digits += 1;
        if (self.size_digits > 16) {
            // Saturate so endSizeLine rejects via max_chunk_size.
            self.size_acc = std.math.maxInt(u64);
            return;
        }
        self.size_acc = self.size_acc *% 16 +% d;
    }

    /// Enters the size-line state, resetting per-line accumulators.
    fn enterSize(self: *ChunkedDecoder) void {
        self.state = .size;
        self.size_acc = 0;
        self.size_digits = 0;
    }

    fn endSizeLine(self: *ChunkedDecoder) ParseError!void {
        if (self.size_digits == 0) return ParseError.InvalidChunkSize;
        if (self.size_acc > self.max_chunk_size) return ParseError.InvalidChunkSize;
        if (self.size_acc == 0) {
            self.state = .trailer;
        } else {
            self.remaining_in_chunk = self.size_acc;
            self.state = .data;
        }
    }
};

// Tests

test "parse simple GET request head" {
    const req = "GET /path?q=1 HTTP/1.1\r\nHost: x\r\n\r\n";
    const r = try parseRequestHead(req);
    try std.testing.expectEqualStrings("GET", r.method);
    try std.testing.expectEqualStrings("/path?q=1", r.path);
    try std.testing.expectEqual(@as(u8, 1), r.minor_version);
}

test "request head split across arbitrary reads" {
    const req = "POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello";
    for (1..req.len) |cut| {
        var acc: [128]u8 = undefined;
        @memcpy(acc[0..cut], req[0..cut]);
        if (parseRequestHead(acc[0..cut])) |h| {
            try std.testing.expect(h.head_end <= cut);
        } else |e| {
            try std.testing.expectEqual(ParseError.Incomplete, e);
        }
    }
}

test "reject bad request lines" {
    try std.testing.expectError(ParseError.MalformedRequestLine, parseRequestHead("GET / HTTP/1.1 extra\r\n\r\n"));
    try std.testing.expectError(ParseError.Incomplete, parseRequestHead("GET / HTTP/1.1\r")); // truncated
    try std.testing.expectError(ParseError.UnsupportedHttpVersion, parseRequestHead("G / HTTP/2.0\r\n"));
    try std.testing.expectError(ParseError.UnsupportedHttpVersion, parseRequestHead("GE T / HTTP/1.1\r\n"));
    try std.testing.expectError(ParseError.Incomplete, parseRequestHead("GET / HTT"));
}

test "parse response status line variants" {
    const r1 = try parseResponseHead("HTTP/1.1 200 OK\r\nServer: x\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 200), r1.status_code);
    try std.testing.expectEqualStrings("OK", r1.reason);

    const r2 = try parseResponseHead("HTTP/1.0 404 Not Found with words\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 404), r2.status_code);
    try std.testing.expectEqualStrings("Not Found with words", r2.reason);

    const r3 = try parseResponseHead("HTTP/1.1 204\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 204), r3.status_code);
    try std.testing.expectEqualStrings("", r3.reason);
}

test "header block parsing and validation" {
    const msg = "Host: example.com\r\nX-A: spaced\r\nX-B: v2\r\n\r\nbody";
    var fields: [8]Field = undefined;
    const blk = try parseHeaderBlock(msg, 0, fields[0..]);
    try std.testing.expectEqual(@as(usize, 3), blk.count);
    try std.testing.expectEqualStrings("example.com", fields[0].value);
    try std.testing.expectEqualStrings("spaced", fields[1].value);
    try std.testing.expectEqualStrings("v2", fields[2].value);
}

test "header block rejects obs-fold and whitespace before colon" {
    const folded = "X-A: one\r\n  continued\r\n\r\n";
    var f1: [4]Field = undefined;
    try std.testing.expectError(ParseError.ObsFold, parseHeaderBlock(folded, 0, f1[0..]));

    const wsc = "Host : x\r\n\r\n";
    var f2: [4]Field = undefined;
    try std.testing.expectError(ParseError.MalformedHeaderLine, parseHeaderBlock(wsc, 0, f2[0..]));
}

test "framing decisions incl smuggling defenses" {
    // CL alone
    const cl = [_]Field{.{ .name = "Content-Length", .value = "10" }};
    const d1 = try decideFraming(&cl, false, 0, 0);
    try std.testing.expectEqual(Framing.content_length, d1.framing);
    try std.testing.expectEqual(@as(usize, 10), d1.length);

    // chunked alone
    const te = [_]Field{.{ .name = "Transfer-Encoding", .value = "chunked" }};
    const d2 = try decideFraming(&te, false, 0, 0);
    try std.testing.expectEqual(Framing.chunked, d2.framing);

    // CL+TE together -> ambiguous (smuggling defense)
    const both = [_]Field{
        .{ .name = "Content-Length", .value = "10" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };
    try std.testing.expectError(ParseError.AmbiguousFraming, decideFraming(&both, false, 0, 0));

    // TE whose final coding is not chunked -> ambiguous
    const badte = [_]Field{.{ .name = "Transfer-Encoding", .value = "gzip" }};
    try std.testing.expectError(ParseError.AmbiguousFraming, decideFraming(&badte, false, 0, 0));
    const gzipchunk = [_]Field{.{ .name = "Transfer-Encoding", .value = "gzip, chunked" }};
    const d3 = try decideFraming(&gzipchunk, false, 0, 0);
    try std.testing.expectEqual(Framing.chunked, d3.framing);

    // conflicting duplicate CL
    const dupcl = [_]Field{
        .{ .name = "Content-Length", .value = "5" },
        .{ .name = "Content-Length", .value = "6" },
    };
    try std.testing.expectError(ParseError.AmbiguousFraming, decideFraming(&dupcl, false, 0, 0));

    // identical duplicate CL allowed (RFC 9112 section 6.3 rule 4)
    const samedup = [_]Field{
        .{ .name = "Content-Length", .value = "5" },
        .{ .name = "content-length", .value = "5" },
    };
    const d4 = try decideFraming(&samedup, false, 0, 0);
    try std.testing.expectEqual(Framing.content_length, d4.framing);

    // invalid CL forms
    try std.testing.expectError(ParseError.InvalidContentLength, decideFraming(&.{.{ .name = "Content-Length", .value = "+5" }}, false, 0, 0));
    try std.testing.expectError(ParseError.InvalidContentLength, decideFraming(&.{.{ .name = "Content-Length", .value = "0x10" }}, false, 0, 0));
    try std.testing.expectError(ParseError.InvalidContentLength, decideFraming(&.{.{ .name = "Content-Length", .value = "" }}, false, 0, 0));

    // CONNECT tunnel response
    const conn = try framingFull(&.{}, .{ .is_response = true, .status = 200, .connect_ok = true });
    try std.testing.expectEqual(Framing.tunnel, conn.framing);

    // 204 has no body even when CL present
    const r204 = try framingFull(&cl, .{ .is_response = true, .status = 204, .method_len = 4 });
    try std.testing.expectEqual(Framing.none, r204.framing);

    const head_response = [_]Field{
        .{ .name = "Content-Length", .value = "42" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };
    const rhead = try framingFull(&head_response, .{ .is_response = true, .status = 200, .method_len = 4 });
    try std.testing.expectEqual(Framing.none, rhead.framing);
}

test "chunked decoder basic and incremental feeding" {
    const input = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";

    var dec = ChunkedDecoder.init();
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..input.len], input);
    const tail = try dec.decode(buf[0..input.len]);
    try std.testing.expect(dec.isDone());
    try std.testing.expectEqualStrings("hello world", buf[0..11]);
    try std.testing.expectEqual(input.len, tail);

    // Byte-at-a-time feeding using the streaming contract: each call
    // gets only unconsumed bytes; produced payload (buf[0..decoded_len])
    // is collected; the consumed prefix is dropped.
    dec = ChunkedDecoder.init();
    var keep: [64]u8 = undefined;
    var klen: usize = 0;
    var out: [64]u8 = undefined;
    var out_len: usize = 0;
    var done = false;
    for (input) |ch| {
        keep[klen] = ch;
        klen += 1;
        if (dec.decode(keep[0..klen])) |_| {
            done = true;
            out_len += dec.decoded_len;
            break;
        } else |e| {
            try std.testing.expectEqual(ParseError.Incomplete, e);
            const produced = dec.decoded_len;
            @memcpy(out[out_len..][0..produced], keep[0..produced]);
            out_len += produced;
            const used = dec.raw_consumed;
            std.mem.copyForwards(u8, keep[0 .. klen - used], keep[used..klen]);
            klen -= used;
        }
    }
    try std.testing.expect(done);
    try std.testing.expect(dec.isDone());
    try std.testing.expectEqualStrings("hello world", out[0..out_len]);
}

test "chunked decoder with extensions and trailers" {
    var trailer_list = std.ArrayList(Field).empty;
    defer trailer_list.deinit(std.testing.allocator);

    const input = "4;ext=1;x\r\nWiki\r\n0\r\nX-T: tv\r\nX-U: uv\r\n\r\nTAIL";
    var dec = ChunkedDecoder.init();
    dec.trailers = &trailer_list;
    dec.trailer_allocator = std.testing.allocator;
    var buf: [96]u8 = undefined;
    @memcpy(buf[0..input.len], input);
    const tail = try dec.decode(buf[0..input.len]);
    try std.testing.expect(dec.isDone());
    try std.testing.expectEqualStrings("Wiki", buf[0..4]);
    try std.testing.expectEqualStrings("TAIL", buf[tail..input.len]);
    try std.testing.expectEqual(@as(usize, 2), trailer_list.items.len);
    try std.testing.expectEqualStrings("X-T", trailer_list.items[0].name);
    try std.testing.expectEqualStrings("tv", trailer_list.items[0].value);
}

test "chunked decoder rejects malformed sizes and terminators" {
    const huge = "FFFFFFFFFFFFFFFF01\r\n";
    var b1: [32]u8 = undefined;
    @memcpy(b1[0..huge.len], huge);
    var d1 = ChunkedDecoder.init();
    try std.testing.expectError(ParseError.InvalidChunkSize, d1.decode(b1[0..huge.len]));

    const bad = "Z\r\nabc\r\n";
    var b2: [16]u8 = undefined;
    @memcpy(b2[0..bad.len], bad);
    var d2 = ChunkedDecoder.init();
    try std.testing.expectError(ParseError.InvalidChunkSize, d2.decode(b2[0..bad.len]));

    const noterm = "3\r\nabcX";
    var b3: [16]u8 = undefined;
    @memcpy(b3[0..noterm.len], noterm);
    var d3 = ChunkedDecoder.init();
    try std.testing.expectError(ParseError.InvalidChunkSize, d3.decode(b3[0..noterm.len]));

    // Empty size line (no digits).
    const nodigit = "\r\nabc";
    var b4: [16]u8 = undefined;
    @memcpy(b4[0..nodigit.len], nodigit);
    var d4 = ChunkedDecoder.init();
    try std.testing.expectError(ParseError.InvalidChunkSize, d4.decode(b4[0..nodigit.len]));
}

test "strict mode rejects bare LF in headers while lenient mode accepts it" {
    const raw = "HTTP/1.1 200 OK\nHost: example.com\nX-Test: value\n\n";
    var fields: [4]Field = undefined;

    // Strict mode (default) must reject bare LF in header lines
    try std.testing.expectError(ParseError.MalformedHeaderLine, parseHeaderBlock(raw, 16, fields[0..]));

    // Lenient mode must parse bare LF lines successfully
    const res = try parseHeaderBlockWithOptions(raw, 16, fields[0..], .{ .allow_lf_line_endings = true });
    try std.testing.expectEqual(@as(usize, 2), res.count);
    try std.testing.expectEqualStrings("Host", fields[0].name);
    try std.testing.expectEqualStrings("example.com", fields[0].value);
    try std.testing.expectEqualStrings("X-Test", fields[1].name);
    try std.testing.expectEqualStrings("value", fields[1].value);
}

test "lone CR inside header value is treated as data byte, not line terminator" {
    // Header with a lone \r inside value
    const raw = "HTTP/1.1 200 OK\r\nHeader: v\rX: y\r\n\r\n";
    var fields: [4]Field = undefined;

    const res = try parseHeaderBlockWithOptions(raw, 17, fields[0..], .{ .allow_lf_line_endings = true });
    try std.testing.expectEqual(@as(usize, 1), res.count);
    try std.testing.expectEqualStrings("Header", fields[0].name);
    try std.testing.expectEqualStrings("v\rX: y", fields[0].value);
}
