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
const list_writer = @import("../util/list_writer.zig");
const types = @import("types.zig");

/// Standard HTTP header name constants.
/// Using these constants enables compile-time string interning.
pub const HeaderName = struct {
    pub const ACCEPT = "Accept";
    pub const ACCEPT_CHARSET = "Accept-Charset";
    pub const ACCEPT_ENCODING = "Accept-Encoding";
    pub const ACCEPT_LANGUAGE = "Accept-Language";
    pub const AUTHORIZATION = "Authorization";
    pub const CACHE_CONTROL = "Cache-Control";
    pub const CONNECTION = "Connection";
    pub const CONTENT_DISPOSITION = "Content-Disposition";
    pub const CONTENT_ENCODING = "Content-Encoding";
    pub const CONTENT_LENGTH = "Content-Length";
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

    /// Appends a header, allowing multiple values for the same name.
    pub fn append(self: *Self, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
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
        return mem.indexOf(u8, value, "chunked") != null;
    }

    /// Determines if connection should be kept alive based on headers and version.
    pub fn isKeepAlive(self: *const Self, version: types.Version) bool {
        const conn = self.get(HeaderName.CONNECTION);
        if (conn) |c| {
            if (mem.indexOf(u8, c, "close") != null) return false;
            if (mem.indexOf(u8, c, "keep-alive") != null) return true;
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
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
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
