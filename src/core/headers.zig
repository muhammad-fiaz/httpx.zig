//! HTTP Headers Implementation for httpx.zig
//!
//! Provides a high-performance, case-insensitive HTTP header storage with
//! multi-value support per RFC 7230. Features include:
//!
//! - Case-insensitive header name lookups
//! - Multiple values per header name (e.g., Set-Cookie)
//! - Efficient serialization for wire format
//! - Common header name constants for compile-time optimization
//! - Memory-safe ownership model with automatic cleanup

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const list_writer = @import("../io/list_writer.zig");
const types = @import("types.zig");

/// Standard HTTP header name constants.
/// Using these constants enables compile-time string interning.
pub const HeaderName = struct {
    pub const ACCEPT = "Accept";
    pub const ACCEPT_CHARSET = "Accept-Charset";
    pub const ACCEPT_ENCODING = "Accept-Encoding";
    pub const ACCEPT_LANGUAGE = "Accept-Language";
    pub const ACCEPT_RANGES = "Accept-Ranges";
    pub const AUTHORIZATION = "Authorization";
    pub const CACHE_CONTROL = "Cache-Control";
    pub const CONNECTION = "Connection";
    pub const CONTENT_DISPOSITION = "Content-Disposition";
    pub const CONTENT_ENCODING = "Content-Encoding";
    pub const CONTENT_LENGTH = "Content-Length";
    pub const CONTENT_RANGE = "Content-Range";
    pub const CONTENT_TYPE = "Content-Type";
    pub const COOKIE = "Cookie";
    pub const DATE = "Date";
    pub const ETAG = "ETag";
    pub const EXPIRES = "Expires";
    pub const HOST = "Host";
    pub const IF_MATCH = "If-Match";
    pub const IF_MODIFIED_SINCE = "If-Modified-Since";
    pub const IF_NONE_MATCH = "If-None-Match";
    pub const LAST_MODIFIED = "Last-Modified";
    pub const LOCATION = "Location";
    pub const ORIGIN = "Origin";
    pub const PRAGMA = "Pragma";
    pub const PROXY_AUTHORIZATION = "Proxy-Authorization";
    pub const RANGE = "Range";
    pub const REFERER = "Referer";
    pub const RETRY_AFTER = "Retry-After";
    pub const SERVER = "Server";
    pub const SET_COOKIE = "Set-Cookie";
    pub const STRICT_TRANSPORT_SECURITY = "Strict-Transport-Security";
    pub const TRANSFER_ENCODING = "Transfer-Encoding";
    pub const UPGRADE = "Upgrade";
    pub const USER_AGENT = "User-Agent";
    pub const VARY = "Vary";
    pub const WWW_AUTHENTICATE = "WWW-Authenticate";
    pub const X_CONTENT_TYPE_OPTIONS = "X-Content-Type-Options";
    pub const X_FRAME_OPTIONS = "X-Frame-Options";
    pub const X_XSS_PROTECTION = "X-XSS-Protection";
    pub const EXPECT = "Expect";
    pub const IF_UNMODIFIED_SINCE = "If-Unmodified-Since";
    pub const IF_RANGE = "If-Range";
    pub const CONTENT_LANGUAGE = "Content-Language";
    pub const LINK = "Link";
    pub const WARNING = "Warning";
    pub const X_REQUESTED_WITH = "X-Requested-With";
    pub const ACCESS_CONTROL_ALLOW_ORIGIN = "Access-Control-Allow-Origin";
    pub const ACCESS_CONTROL_ALLOW_METHODS = "Access-Control-Allow-Methods";
    pub const ACCESS_CONTROL_ALLOW_HEADERS = "Access-Control-Allow-Headers";
    pub const ACCESS_CONTROL_ALLOW_CREDENTIALS = "Access-Control-Allow-Credentials";
    pub const ACCESS_CONTROL_EXPOSE_HEADERS = "Access-Control-Expose-Headers";
    pub const ACCESS_CONTROL_MAX_AGE = "Access-Control-Max-Age";
    pub const ACCESS_CONTROL_REQUEST_METHOD = "Access-Control-Request-Method";
    pub const ACCESS_CONTROL_REQUEST_HEADERS = "Access-Control-Request-Headers";
    pub const X_FORWARDED_FOR = "X-Forwarded-For";
    pub const X_FORWARDED_PROTO = "X-Forwarded-Proto";
    pub const X_FORWARDED_HOST = "X-Forwarded-Host";
    pub const VIA = "Via";
    pub const KEEP_ALIVE = "Keep-Alive";
    pub const TE = "TE";
    pub const TRAILER = "Trailer";
    pub const CONTENT_SECURITY_POLICY = "Content-Security-Policy";
    pub const REFERRER_POLICY = "Referrer-Policy";
    pub const PERMISSIONS_POLICY = "Permissions-Policy";
    pub const CROSS_ORIGIN_OPENER_POLICY = "Cross-Origin-Opener-Policy";
    pub const CROSS_ORIGIN_RESOURCE_POLICY = "Cross-Origin-Resource-Policy";
    pub const CROSS_ORIGIN_EMBEDDER_POLICY = "Cross-Origin-Embedder-Policy";
};

/// Represents a single HTTP header entry.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
    owned: bool = false,
};

/// HTTP headers collection with case-insensitive lookups.
pub const Headers = struct {
    allocator: Allocator,
    entries: std.ArrayList(Header) = .empty,
    max_headers: usize = 100,

    const Self = @This();

    /// Creates a new empty Headers instance.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Releases all allocated memory.
    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            if (entry.owned) {
                self.allocator.free(entry.name);
                self.allocator.free(entry.value);
            }
        }
        self.entries.deinit(self.allocator);
    }

    /// Returns true if the byte slice contains CR (\r) or LF (\n) characters.
    /// Used to prevent HTTP header injection (CRLF injection) attacks.
    fn containsCRLF(s: []const u8) bool {
        for (s) |c| {
            if (c == '\r' or c == '\n') return true;
        }
        return false;
    }

    /// Returns true if the byte slice contains control characters (0x00-0x1F, 0x7F).
    /// RFC 7230 Section 3.2 forbids control characters in header field values.
    fn containsControlChars(s: []const u8) bool {
        for (s) |c| {
            if (c < 0x20 or c == 0x7F) return true;
        }
        return false;
    }

    /// Appends a header, allowing multiple values for the same name.
    /// Validates that neither name nor value contains CRLF sequences
    /// to prevent HTTP header injection attacks (RFC 7230 Section 3.2).
    /// Header values are also checked for control characters per RFC 7230.
    pub fn append(self: *Self, name: []const u8, value: []const u8) !void {
        if (self.entries.items.len >= self.max_headers) return error.TooManyHeaders;
        if (containsCRLF(name)) return error.InvalidHeaderName;
        if (containsCRLF(value)) return error.InvalidHeaderValue;
        if (containsControlChars(value)) return error.InvalidHeaderValue;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
            .owned = true,
        });
    }

    /// Appends a header only when no value exists for the same name.
    /// Returns true when a new header entry is appended.
    pub fn appendIfMissing(self: *Self, name: []const u8, value: []const u8) !bool {
        if (self.contains(name)) return false;
        try self.append(name, value);
        return true;
    }

    /// Sets a header, replacing any existing values with the same name.
    pub fn set(self: *Self, name: []const u8, value: []const u8) !void {
        self.removeAll(name);
        try self.append(name, value);
    }

    /// Retrieves the first value for a header name (case-insensitive).
    pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    /// Retrieves the first value for a header name or returns a fallback.
    pub fn getOr(self: *const Self, name: []const u8, fallback: []const u8) []const u8 {
        return self.get(name) orelse fallback;
    }

    /// Returns all values for a header name.
    pub fn getAll(self: *const Self, name: []const u8, allocator: Allocator) ![][]const u8 {
        var values = std.ArrayList([]const u8).empty;
        for (self.entries.items) |entry| {
            if (eqlIgnoreCase(entry.name, name)) {
                try values.append(allocator, entry.value);
            }
        }
        return values.toOwnedSlice(allocator);
    }

    /// Returns true if the header exists.
    pub fn contains(self: *const Self, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Removes the first occurrence of a header.
    pub fn remove(self: *Self, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (eqlIgnoreCase(entry.name, name)) {
                if (entry.owned) {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.value);
                }
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Removes all occurrences of a header.
    pub fn removeAll(self: *Self, name: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (eqlIgnoreCase(self.entries.items[i].name, name)) {
                const entry = self.entries.orderedRemove(i);
                if (entry.owned) {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.value);
                }
            } else i += 1;
        }
    }

    /// Returns the number of headers.
    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Returns an iterator over all headers.
    pub fn iterator(self: *const Self) []const Header {
        return self.entries.items;
    }

    /// Clears all headers.
    pub fn clear(self: *Self) void {
        for (self.entries.items) |entry| {
            if (entry.owned) {
                self.allocator.free(entry.name);
                self.allocator.free(entry.value);
            }
        }
        self.entries.clearRetainingCapacity();
    }

    /// Creates a deep copy of the headers.
    pub fn clone(self: *const Self, allocator: Allocator) !Headers {
        var new_headers = Headers.init(allocator);
        for (self.entries.items) |entry| {
            try new_headers.append(entry.name, entry.value);
        }
        return new_headers;
    }

    /// Merges headers from another collection.
    ///
    /// When `overwrite` is true, destination values are replaced per header name.
    /// Otherwise, existing destination values are preserved.
    pub fn mergeFrom(self: *Self, other: *const Self, overwrite: bool) !void {
        for (other.entries.items) |entry| {
            if (overwrite) {
                try self.set(entry.name, entry.value);
            } else {
                _ = try self.appendIfMissing(entry.name, entry.value);
            }
        }
    }

    /// Parses Content-Length header value.
    pub fn getContentLength(self: *const Self) ?u64 {
        const value = self.get(HeaderName.CONTENT_LENGTH) orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }

    /// Returns true if Transfer-Encoding includes chunked.
    pub fn isChunked(self: *const Self) bool {
        const value = self.get(HeaderName.TRANSFER_ENCODING) orelse return false;
        return std.ascii.indexOfIgnoreCase(value, "chunked") != null;
    }

    /// Determines if connection should be kept alive based on headers and version.
    pub fn isKeepAlive(self: *const Self, version: types.Version) bool {
        const conn = self.get(HeaderName.CONNECTION);
        if (conn) |c| {
            if (std.ascii.indexOfIgnoreCase(c, "close") != null) return false;
            if (std.ascii.indexOfIgnoreCase(c, "keep-alive") != null) return true;
        }
        return version == .HTTP_1_1 or version == .HTTP_2 or version == .HTTP_3;
    }

    /// Serializes headers to HTTP wire format.
    pub fn serialize(self: *const Self, writer: anytype) !void {
        for (self.entries.items) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.name, entry.value });
        }
    }

    /// Serializes headers to an allocated string.
    pub fn toSlice(self: *const Self, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(allocator, &buffer);
        try self.serialize(writer);
        return buffer.toOwnedSlice(allocator);
    }
};

/// Case-insensitive string comparison for ASCII.
inline fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Validates a header value: rejects CR, LF, and NUL bytes.
/// Returns true if the value is safe to use in an HTTP header.
pub fn validateHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

/// Validates a header name: rejects control characters (except OWS) and requires non-empty.
/// Returns true if the name is a valid HTTP header field name per RFC 7230.
pub fn validateHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c < 32 or c > 126) return false;
        if (c == ':' and name.len > 1) continue;
    }
    return true;
}

test "validateHeaderValue rejects CRLF and NUL" {
    try std.testing.expect(validateHeaderValue("hello world"));
    try std.testing.expect(validateHeaderValue("application/json; charset=utf-8"));
    try std.testing.expect(!validateHeaderValue("abc\r\nEvil: true"));
    try std.testing.expect(!validateHeaderValue("abc\nEvil: true"));
    try std.testing.expect(!validateHeaderValue("abc\rEvil: true"));
    try std.testing.expect(!validateHeaderValue("abc\x00def"));
}

test "validateHeaderValue empty value" {
    try std.testing.expect(validateHeaderValue(""));
}

test "validateHeaderName valid names" {
    try std.testing.expect(validateHeaderName("Content-Type"));
    try std.testing.expect(validateHeaderName("X-Custom-Header"));
    try std.testing.expect(validateHeaderName("Accept"));
    try std.testing.expect(validateHeaderName("X-Trace-Id-123"));
}

test "validateHeaderName rejects empty" {
    try std.testing.expect(!validateHeaderName(""));
}

test "validateHeaderName rejects control characters" {
    try std.testing.expect(!validateHeaderName("X-Test\x01"));
    try std.testing.expect(!validateHeaderName("X-Test\x1f"));
    try std.testing.expect(!validateHeaderName("X-Test\x7f"));
}

test "Headers basic operations" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
}

test "Headers case insensitivity" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "text/html");
    try std.testing.expectEqualStrings("text/html", headers.get("content-type").?);
    try std.testing.expectEqualStrings("text/html", headers.get("CONTENT-TYPE").?);
}

test "Headers set replaces existing" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("X-Test", "value1");
    try headers.set("X-Test", "value2");
    try std.testing.expectEqualStrings("value2", headers.get("X-Test").?);
    try std.testing.expectEqual(@as(usize, 1), headers.count());
}

test "Headers multiple values" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Set-Cookie", "cookie1=value1");
    try headers.append("Set-Cookie", "cookie2=value2");
    try std.testing.expectEqual(@as(usize, 2), headers.count());
}

test "Headers Content-Length parsing" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Length", "12345");
    try std.testing.expectEqual(@as(u64, 12345), headers.getContentLength().?);
}

test "Headers keep-alive detection" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try std.testing.expect(headers.isKeepAlive(.HTTP_1_1));
    try std.testing.expect(!headers.isKeepAlive(.HTTP_1_0));

    try headers.set("Connection", "keep-alive");
    try std.testing.expect(headers.isKeepAlive(.HTTP_1_0));
}

test "Headers appendIfMissing and getOr" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try std.testing.expect(try headers.appendIfMissing("X-Trace-Id", "abc"));
    try std.testing.expect(!(try headers.appendIfMissing("x-trace-id", "def")));
    try std.testing.expectEqualStrings("abc", headers.getOr("X-Trace-Id", "none"));
    try std.testing.expectEqualStrings("none", headers.getOr("X-Missing", "none"));
}

test "Headers mergeFrom" {
    const allocator = std.testing.allocator;

    var dst = Headers.init(allocator);
    defer dst.deinit();
    try dst.set("Accept", "application/json");

    var src = Headers.init(allocator);
    defer src.deinit();
    try src.set("Accept", "text/plain");
    try src.set("X-Mode", "test");

    try dst.mergeFrom(&src, false);
    try std.testing.expectEqualStrings("application/json", dst.get("Accept").?);
    try std.testing.expectEqualStrings("test", dst.get("X-Mode").?);

    try dst.mergeFrom(&src, true);
    try std.testing.expectEqualStrings("text/plain", dst.get("Accept").?);
}

test "New header constants exist" {
    // Verify new constants are accessible
    try std.testing.expectEqualStrings("Expect", HeaderName.EXPECT);
    try std.testing.expectEqualStrings("If-Unmodified-Since", HeaderName.IF_UNMODIFIED_SINCE);
    try std.testing.expectEqualStrings("If-Range", HeaderName.IF_RANGE);
    try std.testing.expectEqualStrings("TE", HeaderName.TE);
    try std.testing.expectEqualStrings("Trailer", HeaderName.TRAILER);
    try std.testing.expectEqualStrings("X-Forwarded-For", HeaderName.X_FORWARDED_FOR);
    try std.testing.expectEqualStrings("X-Forwarded-Proto", HeaderName.X_FORWARDED_PROTO);
    try std.testing.expectEqualStrings("X-Forwarded-Host", HeaderName.X_FORWARDED_HOST);
    try std.testing.expectEqualStrings("Content-Security-Policy", HeaderName.CONTENT_SECURITY_POLICY);
    try std.testing.expectEqualStrings("Referrer-Policy", HeaderName.REFERRER_POLICY);
    try std.testing.expectEqualStrings("Permissions-Policy", HeaderName.PERMISSIONS_POLICY);
}

test "CRLF injection prevention in header name" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try std.testing.expectError(error.InvalidHeaderName, headers.append("X-Injected\r\nEvil: true", "value"));
    try std.testing.expectError(error.InvalidHeaderName, headers.append("X-Injected\nEvil: true", "value"));
    try std.testing.expectError(error.InvalidHeaderName, headers.append("X-Injected\rEvil: true", "value"));
    try std.testing.expectEqual(@as(usize, 0), headers.count());
}

test "CRLF injection prevention in header value" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try std.testing.expectError(error.InvalidHeaderValue, headers.append("X-Trace-Id", "abc\r\nEvil: true"));
    try std.testing.expectError(error.InvalidHeaderValue, headers.append("X-Trace-Id", "abc\nEvil: true"));
    try std.testing.expectError(error.InvalidHeaderValue, headers.append("X-Trace-Id", "abc\rEvil: true"));
    try std.testing.expectEqual(@as(usize, 0), headers.count());
}

test "Valid headers still work after CRLF validation" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "text/html");
    try headers.append("X-Custom-Header", "hello world");
    try headers.append("Set-Cookie", "session=abc123; Path=/; HttpOnly");
    try std.testing.expectEqual(@as(usize, 3), headers.count());
    try std.testing.expectEqualStrings("text/html", headers.get("Content-Type").?);
}
