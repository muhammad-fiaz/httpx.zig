//! Shared utility helpers used across client/server/core modules.

const std = @import("std");
const mem = std.mem;
const list_writer = @import("../io/list_writer.zig");
const mime = @import("mime.zig");
const io_util = @import("../io/any_io.zig");
const HeaderName = @import("../core/headers.zig").HeaderName;

/// Returns the canonical `std.Io` for the current execution context.
pub const defaultIo = io_util.defaultIo;

/// Returns a real thread-safe `std.Io` suitable for multi-threaded code.
pub const threadIo = io_util.threadIo;

/// Sleeps for `ms` milliseconds using the canonical IO (`u64`, clamped to `i64.max`).
pub const sleepMs = io_util.sleepMs;

/// Sleeps for `ms` milliseconds using the canonical IO (`i64`).
pub const sleepMsI = io_util.sleepMsI;

/// Returns current time in milliseconds since epoch.
pub fn nowMillis() i64 {
    const io = defaultIo();
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Parsed cookie name/value pair from a Set-Cookie header value.
pub const CookiePair = struct {
    name: []const u8,
    value: []const u8,
};

pub const SameSite = enum {
    lax,
    strict,
    none,

    pub fn toHeaderValue(self: @This()) []const u8 {
        return switch (self) {
            .lax => "Lax",
            .strict => "Strict",
            .none => "None",
        };
    }
};

pub const CookieOptions = struct {
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = true,
    same_site: ?SameSite = .lax,
};

pub const MimeMapping = mime.MimeMapping;
pub const defaultMimeMappings = mime.default_mappings;

/// Returns a query parameter value from a raw query string.
///
/// For key-only query entries (e.g. `?debug`), returns an empty slice.
pub fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        const eq_idx = mem.indexOfScalar(u8, part, '=') orelse {
            if (mem.eql(u8, part, key)) return "";
            continue;
        };

        const k = part[0..eq_idx];
        if (!mem.eql(u8, k, key)) continue;
        return part[eq_idx + 1 ..];
    }

    return null;
}

/// Parses the `name=value` segment from a Set-Cookie header value.
///
/// Attributes after `;` are ignored.
pub fn parseSetCookiePair(set_cookie: []const u8) ?CookiePair {
    const semicolon = mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const pair = set_cookie[0..semicolon];
    const eq = mem.indexOfScalar(u8, pair, '=') orelse return null;

    const name = mem.trim(u8, pair[0..eq], " \t");
    const value = mem.trim(u8, pair[eq + 1 ..], " \t");
    if (name.len == 0) return null;

    return .{ .name = name, .value = value };
}

/// Parsed cookie with domain attribute from a Set-Cookie header.
pub const ParsedCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    same_site: ?SameSite = null,
};

/// Parses a Set-Cookie header value extracting name, value, and key attributes.
pub fn parseSetCookie(set_cookie: []const u8) ?ParsedCookie {
    const pair_part = parseSetCookiePair(set_cookie) orelse {
        return null;
    };
    var result = ParsedCookie{
        .name = pair_part.name,
        .value = pair_part.value,
    };

    // Parse attributes after the semicolon
    var it = mem.splitScalar(u8, set_cookie, ';');
    _ = it.next(); // skip the name=value part

    while (it.next()) |attr| {
        const trimmed = mem.trim(u8, attr, " \t");
        if (trimmed.len == 0) continue;

        if (std.ascii.startsWithIgnoreCase(trimmed, "Domain=")) {
            result.domain = mem.trim(u8, trimmed[7..], " \t");
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "Path=")) {
            result.path = mem.trim(u8, trimmed[5..], " \t");
        } else if (std.ascii.eqlIgnoreCase(trimmed, "Secure")) {
            result.secure = true;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "HttpOnly")) {
            result.http_only = true;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "Max-Age=")) {
            result.max_age = std.fmt.parseInt(i64, mem.trim(u8, trimmed[8..], " \t"), 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "Expires=")) {
            result.expires = mem.trim(u8, trimmed[8..], " \t");
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "SameSite=")) {
            const val = mem.trim(u8, trimmed[9..], " \t");
            result.same_site = if (std.ascii.eqlIgnoreCase(val, "Strict"))
                .strict
            else if (std.ascii.eqlIgnoreCase(val, "Lax"))
                .lax
            else if (std.ascii.eqlIgnoreCase(val, "None"))
                .none
            else
                null;
        }
    }

    return result;
}

/// Returns a cookie value from a Cookie header string.
///
/// Example header: `session=abc123; theme=dark`
pub fn cookieValue(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |segment| {
        const part = mem.trim(u8, segment, " \t");
        const eq = mem.indexOfScalar(u8, part, '=') orelse continue;
        const k = mem.trim(u8, part[0..eq], " \t");
        if (!mem.eql(u8, k, name)) continue;
        return mem.trim(u8, part[eq + 1 ..], " \t");
    }
    return null;
}

/// Builds a Set-Cookie header value with common RFC 6265 attributes.
pub fn buildSetCookieHeader(allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const writer = list_writer.init(allocator, &out);

    try writer.print("{s}={s}", .{ name, value });

    if (options.path) |path| {
        try writer.print("; Path={s}", .{path});
    }
    if (options.domain) |domain| {
        try writer.print("; Domain={s}", .{domain});
    }
    if (options.max_age) |max_age| {
        try writer.print("; Max-Age={d}", .{max_age});
    }
    if (options.expires) |expires| {
        try writer.print("; Expires={s}", .{expires});
    }
    if (options.same_site) |same_site| {
        try writer.print("; SameSite={s}", .{same_site.toHeaderValue()});
    }
    if (options.secure) {
        try writer.writeAll("; Secure");
    }
    if (options.http_only) {
        try writer.writeAll("; HttpOnly");
    }

    return out.toOwnedSlice(allocator);
}

/// Returns a best-effort MIME type for a file path extension.
pub fn mimeTypeFromPath(path: []const u8) []const u8 {
    return mime.resolve(path);
}

/// Returns a best-effort MIME type for a file path extension or a custom fallback.
pub fn mimeTypeFromPathOr(path: []const u8, fallback: []const u8) []const u8 {
    return mime.resolveOr(path, fallback);
}

/// Returns a MIME type using caller-provided mappings and fallback.
pub fn mimeTypeFromPathWith(path: []const u8, mappings: []const MimeMapping, fallback: []const u8) []const u8 {
    return mime.resolveWith(path, mappings, fallback);
}

/// Clamps a u64 value to the platform usize maximum.
pub fn clampU64ToUsize(v: u64) usize {
    return @intCast(@min(v, @as(u64, std.math.maxInt(usize))));
}

/// Returns a lowercased copy of ASCII input bytes.
pub fn dupLowerAscii(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
    return out;
}

/// Returns true for connection-specific headers that must not be forwarded in H2/H3.
pub fn isConnectionSpecificHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, HeaderName.CONNECTION) or
        std.ascii.eqlIgnoreCase(name, HeaderName.UPGRADE) or
        std.ascii.eqlIgnoreCase(name, HeaderName.TRANSFER_ENCODING) or
        std.ascii.eqlIgnoreCase(name, "Keep-Alive") or
        std.ascii.eqlIgnoreCase(name, "Proxy-Connection") or
        std.ascii.eqlIgnoreCase(name, "HTTP2-Settings");
}

test "queryValue parses normal and key-only params" {
    const q = "q=zig&lang=en&debug";
    try std.testing.expectEqualStrings("zig", queryValue(q, "q").?);
    try std.testing.expectEqualStrings("en", queryValue(q, "lang").?);
    try std.testing.expectEqualStrings("", queryValue(q, "debug").?);
    try std.testing.expect(queryValue(q, "missing") == null);
}

test "parseSetCookiePair extracts first cookie segment" {
    const p = parseSetCookiePair("session=abc123; Path=/; HttpOnly").?;
    try std.testing.expectEqualStrings("session", p.name);
    try std.testing.expectEqualStrings("abc123", p.value);

    try std.testing.expect(parseSetCookiePair("; Path=/") == null);
}

test "cookieValue parses Cookie header" {
    const header = "session=abc123; theme=dark; csrftoken=xyz";
    try std.testing.expectEqualStrings("abc123", cookieValue(header, "session").?);
    try std.testing.expectEqualStrings("dark", cookieValue(header, "theme").?);
    try std.testing.expect(cookieValue(header, "missing") == null);
}

test "buildSetCookieHeader includes options" {
    const allocator = std.testing.allocator;
    const set_cookie = try buildSetCookieHeader(allocator, "session", "abc123", .{
        .path = "/",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .strict,
    });
    defer allocator.free(set_cookie);

    try std.testing.expect(mem.indexOf(u8, set_cookie, "session=abc123") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "Path=/") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "Max-Age=3600") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "SameSite=Strict") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "Secure") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "HttpOnly") != null);
}

test "parseSetCookie extracts Max-Age and SameSite" {
    const p = parseSetCookie("session=abc123; Max-Age=3600; SameSite=Strict; Secure").?;
    try std.testing.expectEqualStrings("session", p.name);
    try std.testing.expectEqualStrings("abc123", p.value);
    try std.testing.expectEqual(@as(?i64, 3600), p.max_age);
    try std.testing.expectEqual(@as(?SameSite, .strict), p.same_site);
    try std.testing.expect(p.secure);
}

test "parseSetCookie extracts Path attribute" {
    const p = parseSetCookie("theme=dark; Path=/api; HttpOnly").?;
    try std.testing.expectEqualStrings("/api", p.path.?);
    try std.testing.expect(p.http_only);
}

test "parseSetCookie with zero Max-Age deletes cookie" {
    const p = parseSetCookie("old=cookie; Max-Age=0").?;
    try std.testing.expectEqual(@as(?i64, 0), p.max_age);
}

test "parseSetCookie case-insensitive attributes" {
    // MAX-AGE should be parsed (uppercase)
    const p1 = parseSetCookie("val=1; MAX-AGE=300").?;
    try std.testing.expectEqual(@as(?i64, 300), p1.max_age);

    // SAMESITE should be parsed (uppercase)
    const p2 = parseSetCookie("val=1; SAMESITE=Strict").?;
    try std.testing.expectEqual(@as(?SameSite, .strict), p2.same_site);

    // samesite should be parsed (lowercase)
    const p3 = parseSetCookie("val=1; samesite=Lax").?;
    try std.testing.expectEqual(@as(?SameSite, .lax), p3.same_site);

    // DOMAIN should be parsed (uppercase)
    const p4 = parseSetCookie("val=1; DOMAIN=example.com").?;
    try std.testing.expectEqualStrings("example.com", p4.domain.?);

    // EXPIRES should be parsed
    const p5 = parseSetCookie("val=1; Expires=Thu, 01 Dec 2025 16:00:00 GMT").?;
    try std.testing.expectEqualStrings("Thu, 01 Dec 2025 16:00:00 GMT", p5.expires.?);
}

test "parseSetCookie all attributes" {
    const p = parseSetCookie("token=xyz; Domain=.example.com; Path=/api; Secure; HttpOnly; Max-Age=7200; SameSite=None; Expires=Thu, 01 Dec 2025 16:00:00 GMT").?;
    try std.testing.expectEqualStrings("token", p.name);
    try std.testing.expectEqualStrings("xyz", p.value);
    try std.testing.expectEqualStrings(".example.com", p.domain.?);
    try std.testing.expectEqualStrings("/api", p.path.?);
    try std.testing.expect(p.secure);
    try std.testing.expect(p.http_only);
    try std.testing.expectEqual(@as(?i64, 7200), p.max_age);
    try std.testing.expectEqual(@as(?SameSite, .none), p.same_site);
    try std.testing.expectEqualStrings("Thu, 01 Dec 2025 16:00:00 GMT", p.expires.?);
}

test "buildSetCookieHeader with Expires" {
    const allocator = std.testing.allocator;
    const set_cookie = try buildSetCookieHeader(allocator, "sid", "abc", .{
        .expires = "Thu, 01 Dec 2025 16:00:00 GMT",
        .secure = true,
    });
    defer allocator.free(set_cookie);

    try std.testing.expect(mem.indexOf(u8, set_cookie, "sid=abc") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "Expires=Thu, 01 Dec 2025 16:00:00 GMT") != null);
    try std.testing.expect(mem.indexOf(u8, set_cookie, "Secure") != null);
}
