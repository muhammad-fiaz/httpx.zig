//! HTTP/1 semantic rules shared by parser and writer (RFC 9110/9112):
//! request-target forms, Host authority validation, connection
//! persistence, Expect handling, informational responses, and the
//! configurable limits applied while parsing heads.
//!
//! References:
//!   - RFC 9110 Section 5.3 — Request Target
//!   - RFC 9110 Section 7.2 — Host Header
//!   - RFC 9112 Section 9.6 — Connection Persistence
//!   - RFC 9112 Section 9.3 — Expect-Continue

const std = @import("std");

// Limits (configurable; parser.zig defaults derive from these)

pub const Limits = struct {
    max_headers: usize = 128,
    max_name_len: usize = 256,
    max_value_len: usize = 8192,
    /// Total bytes across all header lines (excluding CRLFs).
    max_header_bytes: usize = 32 * 1024,
    max_body_bytes: usize = 64 * 1024 * 1024,
};

pub const default_limits = Limits{};

// Request-target forms (RFC 9112 section 3.2)

pub const TargetForm = enum {
    origin, // /path?query
    absolute, // http://host[:port]/path
    authority, // host:port  (CONNECT only)
    asterisk, // *          (OPTIONS only)

    pub fn allowsForm(method: []const u8, form: TargetForm) bool {
        return switch (form) {
            .authority => std.ascii.eqlIgnoreCase(method, "CONNECT"),
            .asterisk => std.ascii.eqlIgnoreCase(method, "OPTIONS"),
            else => true,
        };
    }
};

fn isTargetChar(c: u8) bool {
    // RFC 3986 pchar + extra safe chars; reject CTL/SP and raw non-ASCII.
    return switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?', '%', '-', '.', '_', '~', '#', '[', ']' => true,
        else => std.ascii.isAlphanumeric(c),
    };
}

/// Classifies and validates an HTTP/1 request target.
/// `method` gates authority-form/asterisk-form legality.
pub fn classifyTarget(method: []const u8, target: []const u8) ?TargetForm {
    if (target.len == 0 or target.len > 8192) return null;
    for (target) |c| {
        if (!isTargetChar(c)) return null;
    }

    if (std.mem.eql(u8, target, "*")) {
        return if (TargetForm.allowsForm(method, .asterisk)) .asterisk else null;
    }
    if (target[0] == '/') return .origin;

    // scheme://authority[...] — require a known-ish scheme shape.
    if (std.mem.indexOf(u8, target, "://")) |i| {
        if (i == 0) return null;
        const scheme = target[0..i];
        for (scheme) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
        }
        const rest = target[i + 3 ..];
        if (rest.len == 0) return null;
        return if (TargetForm.allowsForm(method, .absolute)) .absolute else null;
    }

    // authority-form: host[:port] with no '/' or '?'.
    if (std.mem.indexOfAny(u8, target, "/?#") != null) return null;
    return if (TargetForm.allowsForm(method, .authority)) .authority else null;
}

// Host / authority validation (RFC 9112 section 3.2 + RFC 3986)

/// Validates a Host (or :authority-style) value: reg-name, IPv4 literal,
/// or bracketed IPv6 literal with optional [:port].
pub fn validAuthority(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;

    var host_part = value;
    var port_part: ?[]const u8 = null;

    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (close < 3) return false; // [] minimum
        host_part = value[0 .. close + 1];
        const rest = value[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return false;
            port_part = rest[1..];
        }
        // Rough IPv6 shape inside brackets: hex digits, colons, dots, %zone.
        const inner = value[1..close];
        if (inner.len == 0) return false;
        for (inner) |c| {
            switch (c) {
                ':', '.', '%' => {},
                else => if (!std.ascii.isHex(c)) return false,
            }
        }
    } else {
        if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon| {
            host_part = value[0..colon];
            port_part = value[colon + 1 ..];
        }
        if (host_part.len == 0) return false;
        for (host_part) |c| {
            switch (c) {
                '-', '.', '_' => {},
                else => if (!std.ascii.isAlphanumeric(c)) return false,
            }
        }
    }

    if (port_part) |p| {
        if (p.len == 0 or p.len > 5) return false;
        for (p) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        const n = std.fmt.parseInt(u16, p, 10) catch return false;
        _ = n;
    }
    return true;
}

// Connection persistence (RFC 9110 section 7.6.1 / RFC 9112 section 9.3)

pub const Version = enum { http_1_0, http_1_1 };

pub const ConnectionDirective = enum { keep_alive, close, unspecified };

/// Extracts the strongest Connection token relevant to persistence.
pub fn connectionDirective(headers: []const @import("../http1/parser.zig").Field) ConnectionDirective {
    var result: ConnectionDirective = .unspecified;
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "Connection")) continue;
        var it = std.mem.splitScalar(u8, h.value, ',');
        while (it.next()) |tok_raw| {
            const tok = std.mem.trim(u8, tok_raw, " \t");
            if (std.ascii.eqlIgnoreCase(tok, "keep-alive")) result = .keep_alive;
            if (std.ascii.eqlIgnoreCase(tok, "close")) result = .close;
        }
    }
    return result;
}

/// Whether the connection may process another message afterwards.
pub fn shouldKeepAlive(
    version: Version,
    headers: []const @import("../http1/parser.zig").Field,
) bool {
    return switch (connectionDirective(headers)) {
        .close => false,
        .keep_alive => true,
        .unspecified => version == .http_1_1,
    };
}

/// True when framing is unambiguous enough to allow reuse (e.g. never
/// reuse after a close-delimited response).
pub fn reusableAfter(framing_kind: anytype) bool {
    return switch (framing_kind) {
        .none => false, // close-delimited consumed the connection
        .tunnel => false,
        else => true,
    };
}

// Expect: 100-continue (RFC 9110 section 10.1.1)

pub fn expectsContinue(headers: []const @import("../http1/parser.zig").Field) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Expect")) {
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "100-continue");
        }
    }
    return false;
}

// Informational responses (RFC 9110 section 15.2)

pub fn isInformational(status: u16) bool {
    return status >= 100 and status < 200;
}

/// Statuses whose responses carry NO body regardless of headers.
pub fn bodylessStatus(status: u16) bool {
    return isInformational(status) or status == 204 or status == 304;
}

/// A response to HEAD carries metadata but no payload bytes.
pub fn responseHasBody(method_head: bool, status: u16) bool {
    if (method_head) return false;
    if (bodylessStatus(status)) return false;
    return true;
}

// Trailer field filtering (RFC 9112 section 7.1.3)

/// Framing-sensitive fields that MUST NOT appear in trailers.
pub fn trailerAllowed(name: []const u8) bool {
    const prohibited = [_][]const u8{
        "transfer-encoding", "content-length", "host",
        "trailer",           "te",             "upgrade",
        "connection",        "expect",
    };
    for (prohibited) |p| {
        if (std.ascii.eqlIgnoreCase(p, name)) return false;
    }
    return true;
}

// Tests

test "target classification" {
    try std.testing.expectEqual(TargetForm.origin, classifyTarget("GET", "/a/b?q=1").?);
    try std.testing.expectEqual(TargetForm.absolute, classifyTarget("GET", "http://example.com/x").?);
    try std.testing.expectEqual(TargetForm.authority, classifyTarget("CONNECT", "example.com:443").?);
    try std.testing.expectEqual(TargetForm.asterisk, classifyTarget("OPTIONS", "*").?);
    try std.testing.expect(classifyTarget("GET", "*") == null);
    try std.testing.expect(classifyTarget("GET", "example.com:443") == null); // authority only via CONNECT
    try std.testing.expect(classifyTarget("GET", "") == null);
    try std.testing.expect(classifyTarget("GET", "/has space") == null);
}

test "authority validation incl IPv6" {
    try std.testing.expect(validAuthority("example.com"));
    try std.testing.expect(validAuthority("example.com:8080"));
    try std.testing.expect(validAuthority("192.168.1.1"));
    try std.testing.expect(validAuthority("[::1]:443"));
    try std.testing.expect(validAuthority("[2001:db8::1]"));
    try std.testing.expect(!validAuthority(""));
    try std.testing.expect(!validAuthority("host:port")); // non-numeric port
    try std.testing.expect(!validAuthority("[::1")); // unclosed bracket
    try std.testing.expect(!validAuthority("host:99999")); // port overflow
    try std.testing.expect(validAuthority("-bad")); // RFC 3986 reg-name allows leading '-'
}

test "keep-alive decision by version and directives" {
    const F = @import("../http1/parser.zig").Field;
    const none = [_]F{};
    try std.testing.expect(shouldKeepAlive(.http_1_1, none[0..]));
    try std.testing.expect(!shouldKeepAlive(.http_1_0, none[0..]));

    const ka10 = [_]F{.{ .name = "Connection", .value = "keep-alive" }};
    try std.testing.expect(shouldKeepAlive(.http_1_0, ka10[0..]));

    const cl11 = [_]F{.{ .name = "Connection", .value = "close" }};
    try std.testing.expect(!shouldKeepAlive(.http_1_1, cl11[0..]));

    const multi = [_]F{.{ .name = "connection", .value = "foo, close" }};
    try std.testing.expect(!shouldKeepAlive(.http_1_1, multi[0..]));
}

test "expect and bodyless rules" {
    const F = @import("../http1/parser.zig").Field;
    const exp = [_]F{.{ .name = "Expect", .value = "100-continue" }};
    try std.testing.expect(expectsContinue(exp[0..]));
    const other = [_]F{.{ .name = "Expect", .value = "something-else" }};
    try std.testing.expect(!expectsContinue(other[0..]));

    try std.testing.expect(responseHasBody(false, 200));
    try std.testing.expect(!responseHasBody(true, 200)); // HEAD
    try std.testing.expect(!responseHasBody(false, 204));
    try std.testing.expect(!responseHasBody(false, 304));
    try std.testing.expect(!responseHasBody(false, 103));
    try std.testing.expect(isInformational(100) and !isInformational(200));
}

test "trailer field filtering blocks framing-sensitive names" {
    try std.testing.expect(trailerAllowed("x-custom"));
    try std.testing.expect(!trailerAllowed("Transfer-Encoding"));
    try std.testing.expect(!trailerAllowed("content-length"));
    try std.testing.expect(!trailerAllowed("HOST"));
}
