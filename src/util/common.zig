//! Shared utility helpers used across client/server/core modules.

const std = @import("std");
const mem = std.mem;
const HeaderName = @import("../core/headers.zig").HeaderName;

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
    secure: bool = false,
    http_only: bool = true,
    same_site: ?SameSite = .lax,
};

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
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

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
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "application/octet-stream";

    if (mem.eql(u8, ext, ".html") or mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (mem.eql(u8, ext, ".json")) return "application/json";
    if (mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (mem.eql(u8, ext, ".png")) return "image/png";
    if (mem.eql(u8, ext, ".jpg") or mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (mem.eql(u8, ext, ".gif")) return "image/gif";
    if (mem.eql(u8, ext, ".webp")) return "image/webp";
    if (mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (mem.eql(u8, ext, ".xml")) return "application/xml";
    if (mem.eql(u8, ext, ".pdf")) return "application/pdf";

    return "application/octet-stream";
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

test "mimeTypeFromPath maps known extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeTypeFromPath("index.html"));
    try std.testing.expectEqualStrings("application/json", mimeTypeFromPath("api.json"));
    try std.testing.expectEqualStrings("image/png", mimeTypeFromPath("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeFromPath("archive.bin"));
}
