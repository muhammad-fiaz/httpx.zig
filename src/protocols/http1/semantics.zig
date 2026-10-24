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
    maxHeaders: usize = 128,
    maxNameLen: usize = 256,
    maxValueLen: usize = 8192,
    /// Total bytes across all header lines (excluding CRLFs).
    maxHeaderBytes: usize = 32 * 1024,
    maxBodyBytes: usize = 64 * 1024 * 1024,
};

pub const defaultLimits = Limits{};

// Request-target forms (RFC 9112 section 3.2)

pub const TargetForm = enum {
    origin, // /path?query
    absolute, // http://host[:port]/path
    authority, // host:port  (CONNECT only)
    asterisk, // *          (OPTIONS only)

    pub fn allowsForm(method: []const u8, form: TargetForm) bool {
        return switch (form) {
            .authority => std.mem.eql(u8, method, "CONNECT"),
            .asterisk => std.mem.eql(u8, method, "OPTIONS"),
            .absolute => !std.mem.eql(u8, method, "CONNECT"),
            .origin => !std.mem.eql(u8, method, "CONNECT"),
        };
    }
};

fn isTargetChar(c: u8) bool {
    // RFC 3986 pchar + extra safe chars; reject CTL/SP and raw non-ASCII.
    return switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?', '%', '-', '.', '_', '~', '[', ']' => true,
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
    if (target[0] == '/') return if (TargetForm.allowsForm(method, .origin)) .origin else null;

    // scheme://authority[...] — require a known-ish scheme shape.
    if (std.mem.indexOf(u8, target, "://")) |i| {
        if (i == 0) return null;
        const scheme = target[0..i];
        for (scheme) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
        }
        const rest = target[i + 3 ..];
        if (rest.len == 0) return null;
        _ = @import("../../common/uri.zig").parse(target) catch return null;
        return if (TargetForm.allowsForm(method, .absolute)) .absolute else null;
    }

    // authority-form: host[:port] with no '/' or '?'.
    if (std.mem.indexOfAny(u8, target, "/?#") != null) return null;
    const authority = parseMod.parseAuthority(target) orelse return null;
    if (authority.port == null or !validAuthority(target)) return null;
    return if (TargetForm.allowsForm(method, .authority)) .authority else null;
}

const parseMod = @import("../../common/parse.zig");

// Host / authority validation (RFC 9112 section 3.2 + RFC 3986)

/// Validates a Host (or :authority-style) value: reg-name, IPv4 literal,
/// or bracketed IPv6 literal with optional [:port].
pub fn validAuthority(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    const auth = parseMod.parseAuthority(value) orelse return false;
    if (auth.host.len == 0) return false;
    if (auth.isIpv6) {
        for (auth.host) |c| {
            switch (c) {
                ':', '.', '%' => {},
                else => if (!std.ascii.isHex(c)) return false,
            }
        }
    } else {
        for (auth.host) |c| {
            switch (c) {
                '-', '.', '_' => {},
                else => if (!std.ascii.isAlphanumeric(c)) return false,
            }
        }
    }
    return true;
}

/// Validates the request-target form and Host field before an HTTP/1 server
/// consumes a body or dispatches the request. HTTP/1.1 requires exactly one
/// Host field; duplicates are rejected for HTTP/1.0 as well because they are
/// ambiguous to intermediaries.
pub fn validRequestTargetAndHost(
    method: []const u8,
    target: []const u8,
    minorVersion: u8,
    fields: []const @import("parser.zig").Field,
) bool {
    const form = classifyTarget(method, target) orelse return false;
    _ = form;

    var hostCount: usize = 0;
    for (fields) |field| {
        if (!parseMod.eqlIgnoreCase(field.name, "Host")) continue;
        hostCount += 1;
        if (!validAuthority(field.value)) return false;
    }
    if (hostCount > 1) return false;
    return minorVersion != 1 or hostCount == 1;
}

// Connection persistence (RFC 9110 section 7.6.1 / RFC 9112 section 9.3)

pub const Version = enum { http10, http11 };

pub const ConnectionDirective = enum { keepAlive, close, unspecified };

/// Extracts the strongest Connection token relevant to persistence.
/// Works with any header slice whose entries have `name` and `value` fields.
pub fn connectionDirective(headers: anytype) ConnectionDirective {
    var result: ConnectionDirective = .unspecified;
    for (headers) |h| {
        if (!parseMod.eqlIgnoreCase(h.name, "Connection")) continue;
        var it = parseMod.TokenListIterator.init(h.value);
        while (it.next()) |tok| {
            if (parseMod.eqlIgnoreCase(tok, "keep-alive")) result = .keepAlive;
            if (parseMod.eqlIgnoreCase(tok, "close")) result = .close;
        }
    }
    return result;
}

/// Whether the connection may process another message afterwards.
pub fn shouldKeepAlive(
    version: Version,
    headers: anytype,
) bool {
    return switch (connectionDirective(headers)) {
        .close => false,
        .keepAlive => true,
        .unspecified => version == .http11,
    };
}

/// True when framing is unambiguous enough to allow reuse (e.g. never
/// reuse after a close-delimited response).
pub fn reusableAfter(framingKind: anytype) bool {
    return switch (framingKind) {
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
pub fn responseHasBody(methodHead: bool, status: u16) bool {
    if (methodHead) return false;
    if (bodylessStatus(status)) return false;
    return true;
}

// Trailer field filtering (RFC 9112 section 7.1.3)

/// Framing-sensitive fields that MUST NOT appear in trailers.
pub fn trailerAllowed(name: []const u8) bool {
    return @import("parser.zig").trailerFieldAllowed(name);
}

// Tests

test "target classification" {
    try std.testing.expectEqual(TargetForm.origin, classifyTarget("GET", "/a/b?q=1").?);
    try std.testing.expectEqual(TargetForm.absolute, classifyTarget("GET", "http://example.com/x").?);
    try std.testing.expectEqual(TargetForm.authority, classifyTarget("CONNECT", "example.com:443").?);
    try std.testing.expectEqual(TargetForm.asterisk, classifyTarget("OPTIONS", "*").?);
    try std.testing.expect(classifyTarget("GET", "*") == null);
    try std.testing.expect(classifyTarget("options", "*") == null);
    try std.testing.expect(classifyTarget("CONNECT", "https://example.com/") == null);
    try std.testing.expect(classifyTarget("CONNECT", "example.com") == null);
    try std.testing.expect(classifyTarget("CONNECT", "/tunnel") == null);
    try std.testing.expect(classifyTarget("connect", "example.com:443") == null);
    try std.testing.expect(classifyTarget("GET", "example.com:443") == null); // authority only via CONNECT
    try std.testing.expect(classifyTarget("GET", "") == null);
    try std.testing.expect(classifyTarget("GET", "/has space") == null);
    try std.testing.expect(classifyTarget("GET", "/has#fragment") == null);
    try std.testing.expect(classifyTarget("GET", "http:///missing-authority") == null);
    try std.testing.expect(classifyTarget("CONNECT", "host:port") == null);
}

test "request target and Host validation" {
    const F = @import("../http1/parser.zig").Field;
    const valid = [_]F{.{ .name = "Host", .value = "example.com:443" }};
    try std.testing.expect(validRequestTargetAndHost("GET", "/", 1, valid[0..]));
    try std.testing.expect(!validRequestTargetAndHost("GET", "/", 1, &[_]F{}));
    try std.testing.expect(!validRequestTargetAndHost("GET", "/", 1, &.{
        .{ .name = "Host", .value = "example.com" },
        .{ .name = "host", .value = "other.example" },
    }));
    try std.testing.expect(!validRequestTargetAndHost("GET", "/", 0, &.{
        .{ .name = "Host", .value = "example.com" },
        .{ .name = "Host", .value = "other.example" },
    }));
    try std.testing.expect(!validRequestTargetAndHost("GET", "/", 1, &.{.{ .name = "Host", .value = "example.com:bad" }}));
    try std.testing.expect(validRequestTargetAndHost("GET", "/", 0, &[_]F{}));
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
    try std.testing.expect(shouldKeepAlive(.http11, none[0..]));
    try std.testing.expect(!shouldKeepAlive(.http10, none[0..]));

    const ka10 = [_]F{.{ .name = "Connection", .value = "keep-alive" }};
    try std.testing.expect(shouldKeepAlive(.http10, ka10[0..]));

    const cl11 = [_]F{.{ .name = "Connection", .value = "close" }};
    try std.testing.expect(!shouldKeepAlive(.http11, cl11[0..]));

    const multi = [_]F{.{ .name = "connection", .value = "foo, close" }};
    try std.testing.expect(!shouldKeepAlive(.http11, multi[0..]));

    const tricky = [_]F{.{ .name = "Connection", .value = "keep-aliveness, preclose" }};
    try std.testing.expect(!shouldKeepAlive(.http10, tricky[0..]));
    try std.testing.expect(shouldKeepAlive(.http11, tricky[0..]));

    const keep = [_]F{.{ .name = "Connection", .value = "Upgrade, Keep-Alive" }};
    try std.testing.expect(shouldKeepAlive(.http10, keep[0..]));
    try std.testing.expect(shouldKeepAlive(.http11, keep[0..]));
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
