//! HTTP/1.0 + HTTP/1.1 message serialization (RFC 9110/9112).
//!
//! All serialization paths validate attacker-influenceable fields
//! (method token, request target, header names/values, status codes,
//! reason phrases) before writing, so response splitting and header
//! injection cannot pass through. Chunked emission supports streaming
//! with optional trailers; bodyless statuses/HEAD never emit a body.

const std = @import("std");
const Allocator = std.mem.Allocator;
const semantics = @import("semantics.zig");

pub const Error = error{
    OutOfMemory,
    InvalidHeader,
    InvalidMethod,
    InvalidTarget,
    InvalidStatus,
    InvalidReason,
    UnsupportedForVersion, // e.g. chunked for HTTP/1.0
};

// ---------------------------------------------------------------------------
// Validators
// ---------------------------------------------------------------------------

pub fn validToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    for (s) |c| {
        switch (c) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => if (!std.ascii.isAlphanumeric(c)) return false,
        }
    }
    return true;
}

/// Field values: VCHAR/SP/HTAB/obs-text; no CR/LF/NUL (injection-proof).
pub fn validHeaderValue(value: []const u8) bool {
    if (value.len > 8192) return false;
    for (value) |c| {
        const ok = c == '\t' or c == ' ' or (c >= 0x21 and c != 0x7F);
        if (!ok) return false;
    }
    return true;
}

pub fn validStatus(code: u16) bool {
    return code >= 100 and code <= 999;
}

fn validReason(reason: []const u8) bool {
    for (reason) |c| {
        // Reason phrase: HTAB / SP / VCHAR / obs-text (no CR/LF).
        const ok = c == '\t' or c == ' ' or (c >= 0x21 and c != 0x7F);
        if (!ok) return false;
    }
    return true;
}

fn appendHeader(out: *std.ArrayList(u8), gpa: Allocator, name: []const u8, value: []const u8) Error!void {
    if (!validToken(name)) return Error.InvalidHeader;
    // No leading/trailing whitespace in emitted value.
    var v = value;
    while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
    while (v.len > 0 and (v[v.len - 1] == ' ' or v[v.len - 1] == '\t')) v = v[0 .. v.len - 1];
    if (!validHeaderValue(v)) return Error.InvalidHeader;
    out.appendSlice(gpa, name) catch return Error.OutOfMemory;
    out.appendSlice(gpa, ": ") catch return Error.OutOfMemory;
    out.appendSlice(gpa, v) catch return Error.OutOfMemory;
    out.appendSlice(gpa, "\r\n") catch return Error.OutOfMemory;
}

pub const Header = struct { name: []const u8, value: []const u8 };

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const RequestOptions = struct {
    minor_version: u8 = 1, // 0 => HTTP/1.0
    host: []const u8 = "",
    headers: []const Header = &.{},
    /// "close" | "keep-alive" | "" (default per version)
    connection: []const u8 = "",
    /// Emit Transfer-Encoding: chunked instead of Content-Length.
    chunked: bool = false,
};

/// Serializes a complete request with a fully buffered body.
pub fn buildRequest(
    allocator: Allocator,
    method: []const u8,
    target: []const u8,
    body: ?[]const u8,
    opts: RequestOptions,
) Error![]u8 {
    if (!validToken(method)) return Error.InvalidMethod;

    const target_form = @import("semantics.zig").classifyTarget(method, target) orelse
        return Error.InvalidTarget;
    _ = target_form;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    out.appendSlice(allocator, method) catch return Error.OutOfMemory;
    out.append(allocator, ' ') catch return Error.OutOfMemory;
    out.appendSlice(allocator, target) catch return Error.OutOfMemory;
    out.appendSlice(allocator, " HTTP/1.") catch return Error.OutOfMemory;
    out.append(allocator, '0' + @as(u8, @intCast(opts.minor_version))) catch return Error.OutOfMemory;
    out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;

    if (opts.host.len > 0) {
        try appendHeader(&out, allocator, "Host", opts.host);
    } else if (opts.minor_version >= 1) {
        // HTTP/1.1 requires Host on non-absolute-form requests.
        const absolute = std.mem.indexOf(u8, target, "://") != null;
        if (!absolute) return Error.InvalidHeader;
    }

    for (opts.headers) |h| try appendHeader(&out, allocator, h.name, h.value);

    if (opts.connection.len > 0) {
        try appendHeader(&out, allocator, "Connection", opts.connection);
    }

    const has_body = body != null and body.?.len > 0;
    if (has_body or opts.chunked) {
        var declared = false;
        for (opts.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) declared = true;
        }
        if (opts.chunked) {
            if (opts.minor_version == 0) return Error.UnsupportedForVersion;
            try appendHeader(&out, allocator, "Transfer-Encoding", "chunked");
        } else if (!declared) {
            var num_buf: [20]u8 = undefined;
            const n = std.fmt.bufPrint(&num_buf, "{d}", .{body.?.len}) catch unreachable;
            try appendHeader(&out, allocator, "Content-Length", n);
        }
    }

    out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;
    if (has_body) out.appendSlice(allocator, body.?) catch return Error.OutOfMemory;

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

pub fn reasonPhrase(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        422 => "Unprocessable Entity",
        426 => "Upgrade Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        else => "",
    };
}

pub const ResponseOptions = struct {
    minor_version: u8 = 1,
    headers: []const Header = &.{},
    connection: []const u8 = "",
    chunked: bool = false,
    /// True when serializing the head of an UPGRADEd/tunneled exchange so
    /// no body framing is emitted.
    upgrade: bool = false,
};

fn writeHead(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    status_line: []const u8,
    headers: []const Header,
    connection: []const u8,
) Error!void {
    out.appendSlice(gpa, status_line) catch return Error.OutOfMemory;
    for (headers) |h| try appendHeader(out, gpa, h.name, h.value);
    if (connection.len > 0) try appendHeader(out, gpa, "Connection", connection);
}

fn fmtStatusLine(buf: []u8, minor: u8, code: u16, reason: []const u8) Error![]const u8 {
    if (!validStatus(code)) return Error.InvalidStatus;
    if (!validReason(reason)) return Error.InvalidReason;
    if (reason.len > 0) {
        return std.fmt.bufPrint(buf, "HTTP/1.{d} {d} {s}\r\n", .{ minor, code, reason }) catch Error.OutOfMemory;
    }
    return std.fmt.bufPrint(buf, "HTTP/1.{d} {d}\r\n", .{ minor, code }) catch Error.OutOfMemory;
}

/// Serializes a complete response with buffered body.
/// `method_head` suppresses the body while preserving metadata framing.
pub fn buildResponse(
    allocator: Allocator,
    status_code: u16,
    reason_in: []const u8,
    body: ?[]const u8,
    opts: ResponseOptions,
    method_head: bool,
) Error![]u8 {
    const reason = if (reason_in.len > 0) reason_in else reasonPhrase(status_code);

    var line_buf: [64]u8 = undefined;
    const status_line = try fmtStatusLine(line_buf[0..], opts.minor_version, status_code, reason);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeHead(&out, allocator, status_line, opts.headers, opts.connection);

    const no_body_status = semantics.bodylessStatus(status_code);
    const wants_body = body != null and body.?.len > 0;

    if (no_body_status or method_head or opts.upgrade) {
        // Metadata only: explicit Content-Length allowed when caller
        // supplied it via headers (e.g., HEAD of a GET); nothing auto-added.
        out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;

        return out.toOwnedSlice(allocator);
    }

    if (status_code >= 200) {
        if (opts.chunked) {
            if (opts.minor_version == 0) return Error.UnsupportedForVersion;
            try appendHeader(&out, allocator, "Transfer-Encoding", "chunked");
        } else {
            var declared = false;
            for (opts.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-length")) declared = true;
            }
            if (!declared) {
                var num_buf: [20]u8 = undefined;
                const n = std.fmt.bufPrint(&num_buf, "{d}", .{if (wants_body) body.?.len else 0}) catch unreachable;
                try appendHeader(&out, allocator, "Content-Length", n);
            }
        }
    } else {
        // 1xx responses have no body and end at the blank line.
        out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;
        return out.toOwnedSlice(allocator);
    }

    out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;
    if (wants_body) out.appendSlice(allocator, body.?) catch return Error.OutOfMemory;

    return out.toOwnedSlice(allocator);
}

/// Builds a bare informational response head (100 Continue, 103 Early Hints).
pub fn buildInformational(
    allocator: Allocator,
    status_code: u16,
    headers: []const Header,
) Error![]u8 {
    if (!semantics.isInformational(status_code)) return Error.InvalidStatus;
    return buildResponse(allocator, status_code, "", null, .{ .headers = headers }, false);
}

/// CONNECT 2xx success head: no framing, tunnel begins after blank line.
pub fn buildConnectTunnelHead(
    allocator: Allocator,
    minor_version: u8,
    status_code: u16,
    headers: []const Header,
) Error![]u8 {
    if (status_code < 200 or status_code >= 300) return Error.InvalidStatus;
    var line_buf: [64]u8 = undefined;
    const line = try fmtStatusLine(line_buf[0..], minor_version, status_code, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeHead(&out, allocator, line, headers, "");
    out.appendSlice(allocator, "\r\n") catch return Error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Chunked emission (streaming)
// ---------------------------------------------------------------------------

pub const TrailerField = Header;

/// Emits one complete chunk (size line + data + CRLF) into `out`.
pub fn writeChunk(out: *std.ArrayList(u8), gpa: Allocator, data: []const u8) Error!void {
    var size_buf: [18]u8 = undefined;
    const hex = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;
    out.appendSlice(gpa, hex) catch return Error.OutOfMemory;
    out.appendSlice(gpa, data) catch return Error.OutOfMemory;
    out.appendSlice(gpa, "\r\n") catch return Error.OutOfMemory;
}

/// Emits the terminating zero chunk plus validated trailers and final CRLF.
pub fn finishChunked(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    trailers: []const TrailerField,
) Error!void {
    out.appendSlice(gpa, "0\r\n") catch return Error.OutOfMemory;
    for (trailers) |t| {
        if (!semantics.trailerAllowed(t.name)) continue;
        try appendHeader(out, gpa, t.name, t.value);
    }
    out.appendSlice(gpa, "\r\n") catch return Error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "request serialization 1.0 vs 1.1" {
    const a = std.testing.allocator;
    const r10 = try buildRequest(a, "GET", "/", null, .{ .minor_version = 0 });
    defer a.free(r10);
    try std.testing.expect(std.mem.startsWith(u8, r10, "GET / HTTP/1.0\r\n"));
    // No Host auto-required for 1.0.
    try std.testing.expect(std.mem.indexOf(u8, r10, "Host:") == null);

    const r11 = try buildRequest(a, "GET", "/x", null, .{ .host = "ex.com" });
    defer a.free(r11);
    try std.testing.expect(std.mem.indexOf(u8, r11, "Host: ex.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r11, "HTTP/1.1") != null);

    // HTTP/1.1 origin-form without Host must fail loudly.
    try std.testing.expectError(Error.InvalidHeader, buildRequest(a, "GET", "/x", null, .{}));
}

test "request methods and targets validated" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.InvalidMethod, buildRequest(a, "BAD METHOD", "/", null, .{}));
    try std.testing.expectError(Error.InvalidTarget, buildRequest(a, "GET", "* ", null, .{}));
    // Custom extension method is fine.
    const custom = try buildRequest(a, "PROPFIND", "/", null, .{ .host = "x" });
    defer a.free(custom);
    try std.testing.expect(std.mem.startsWith(u8, custom, "PROPFIND / HTTP/1.1"));
}

test "request content-length and chunked selection" {
    const a = std.testing.allocator;
    const cl = try buildRequest(a, "POST", "/p", "hello", .{ .host = "x" });
    defer a.free(cl);
    std.debug.print("\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, cl, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, cl, "\r\n\r\nhello"));

    const te = try buildRequest(a, "POST", "/p", null, .{ .chunked = true, .host = "x" });
    defer a.free(te);
    try std.testing.expect(std.mem.indexOf(u8, te, "Transfer-Encoding: chunked\r\n") != null);

    // HTTP/1.0 cannot use chunked.
    try std.testing.expectError(
        Error.UnsupportedForVersion,
        buildRequest(a, "POST", "/p", null, .{ .chunked = true, .minor_version = 0, .host = "x" }),
    );
}

test "response bodyless statuses and HEAD" {
    const a = std.testing.allocator;
    const b = "ignored";

    const r204 = try buildResponse(a, 204, "", b, .{}, false);
    defer a.free(r204);
    try std.testing.expect(std.mem.endsWith(u8, r204, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, r204, "Content-Length") == null);

    const head = try buildResponse(a, 200, "OK", b, .{}, true);
    defer a.free(head);
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, b) == null); // no body

    const ok200 = try buildResponse(a, 200, "", b, .{}, false);
    defer a.free(ok200);
    try std.testing.expect(std.mem.indexOf(u8, ok200, "Content-Length: 7\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, ok200, "\r\n\r\n" ++ b));
}

test "informational and connect heads" {
    const a = std.testing.allocator;
    const c100 = try buildInformational(a, 100, &.{});
    defer a.free(c100);
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", c100);

    const hints = [_]Header{.{ .name = "Link", .value = "</style.css>; rel=preload" }};
    const e103 = try buildInformational(a, 103, hints[0..]);
    defer a.free(e103);
    try std.testing.expect(std.mem.indexOf(u8, e103, "103 Early Hints") != null);

    try std.testing.expectError(Error.InvalidStatus, buildInformational(a, 200, &.{}));

    const tun = try buildConnectTunnelHead(a, 1, 200, &.{});
    defer a.free(tun);
    try std.testing.expect(std.mem.startsWith(u8, tun, "HTTP/1.1 200\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, tun, "\r\n\r\n"));
}

test "chunked emission with trailers and prohibited filtering" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);

    try writeChunk(&out, a, "hello ");
    try writeChunk(&out, a, "world");
    const trailers = [_]TrailerField{
        .{ .name = "X-Sum", .value = "10" },
        .{ .name = "Content-Length", .value = "99" }, // filtered
    };
    try finishChunked(&out, a, trailers[0..]);

    try std.testing.expect(std.mem.startsWith(u8, out.items, "6\r\nhello \r\n5\r\nworld\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "X-Sum: 10\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, out.items, "\r\n\r\n"));

    // Round-trip through the parser's chunked decoder.
    const p = @import("parser.zig");
    var dec = p.ChunkedDecoder.init();
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..out.items.len], out.items);
    const tail = try dec.decode(buf[0..out.items.len]);
    try std.testing.expect(dec.isDone());
    try std.testing.expectEqual(@as(u64, 11), dec.total_decoded);
    try std.testing.expectEqual(out.items.len, tail);
}

test "header injection attempts rejected" {
    const a = std.testing.allocator;
    const evil_headers = [_]Header{
        .{ .name = "X-Evil", .value = "v\r\nInjected: yes" },
    };
    try std.testing.expectError(Error.InvalidHeader, buildRequest(a, "GET", "/", null, .{ .headers = evil_headers[0..], .host = "h" }));

    try std.testing.expectError(Error.InvalidTarget, buildRequest(a, "GET", "/a\r\nX: y", null, .{}));
    try std.testing.expectError(Error.InvalidReason, buildResponse(a, 200, "OK\r\nEvil: x", null, .{}, false));
}
