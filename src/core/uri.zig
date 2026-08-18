//! URI Parsing and Manipulation for httpx.zig
//!
//! Implements URI parsing according to RFC 3986 with support for:
//!
//! - Full URI parsing (scheme, userinfo, host, port, path, query, fragment)
//! - Percent-encoding and decoding
//! - Path normalization
//! - Query string building
//! - Automatic port detection for common schemes

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const list_writer = @import("../io/list_writer.zig");
const PercentEncoding = @import("../data/encoding.zig").PercentEncoding;

/// Parsed URI structure per RFC 3986.
pub const Uri = struct {
    scheme: ?[]const u8 = null,
    userinfo: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    path: []const u8 = "/",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
    raw: []const u8,

    const Self = @This();

    /// Parses a URI string into its components.
    pub fn parse(uri_string: []const u8) !Self {
        var uri = Self{ .raw = uri_string };
        var remaining = uri_string;

        if (mem.indexOf(u8, remaining, "://")) |scheme_end| {
            uri.scheme = remaining[0..scheme_end];
            remaining = remaining[scheme_end + 3 ..];
        }

        if (mem.indexOf(u8, remaining, "#")) |frag_start| {
            uri.fragment = remaining[frag_start + 1 ..];
            remaining = remaining[0..frag_start];
        }

        if (mem.indexOf(u8, remaining, "?")) |query_start| {
            uri.query = remaining[query_start + 1 ..];
            remaining = remaining[0..query_start];
        }

        if (mem.indexOf(u8, remaining, "/")) |path_start| {
            uri.path = remaining[path_start..];
            remaining = remaining[0..path_start];
        } else {
            uri.path = "/";
        }

        if (mem.indexOf(u8, remaining, "@")) |auth_end| {
            uri.userinfo = remaining[0..auth_end];
            remaining = remaining[auth_end + 1 ..];
        }

        if (remaining.len > 0 and remaining[0] == '[') {
            if (mem.indexOf(u8, remaining, "]")) |bracket_end| {
                uri.host = remaining[1..bracket_end];
                remaining = remaining[bracket_end + 1 ..];
            }
        }

        if (mem.lastIndexOf(u8, remaining, ":")) |port_sep| {
            if (std.fmt.parseInt(u16, remaining[port_sep + 1 ..], 10)) |port| {
                uri.port = port;
                remaining = remaining[0..port_sep];
            } else |_| {}
        }

        if (remaining.len > 0 and uri.host == null) {
            uri.host = remaining;
        }

        return uri;
    }

    /// Returns the effective port, using scheme defaults if not specified.
    pub fn effectivePort(self: Self) u16 {
        if (self.port) |p| return p;
        if (self.scheme) |s| {
            if (mem.eql(u8, s, "https")) return 443;
            if (mem.eql(u8, s, "http")) return 80;
            if (mem.eql(u8, s, "ws")) return 80;
            if (mem.eql(u8, s, "wss")) return 443;
            if (mem.eql(u8, s, "ftp")) return 21;
        }
        return 80;
    }

    /// Returns true if the scheme requires TLS.
    pub fn isTLS(self: Self) bool {
        if (self.scheme) |s| {
            return mem.eql(u8, s, "https") or mem.eql(u8, s, "wss");
        }
        return false;
    }

    /// Builds the request path including query string.
    pub fn requestPath(self: Self, allocator: Allocator) ![]u8 {
        if (self.query) |q| {
            return std.fmt.allocPrint(allocator, "{s}?{s}", .{ self.path, q });
        }
        return allocator.dupe(u8, self.path);
    }

    /// Reconstructs the full URI string.
    pub fn format(self: Self, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(allocator, &buffer);

        if (self.scheme) |s| try writer.print("{s}://", .{s});
        if (self.userinfo) |u| try writer.print("{s}@", .{u});
        if (self.host) |h| try writer.print("{s}", .{h});
        if (self.port) |p| try writer.print(":{d}", .{p});
        try writer.print("{s}", .{self.path});
        if (self.query) |q| try writer.print("?{s}", .{q});
        if (self.fragment) |f| try writer.print("#{s}", .{f});

        return buffer.toOwnedSlice(allocator);
    }

    /// Returns the authority component (userinfo@host:port).
    pub fn authority(self: Self, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(allocator, &buffer);

        if (self.userinfo) |u| try writer.print("{s}@", .{u});
        if (self.host) |h| try writer.print("{s}", .{h});
        if (self.port) |p| try writer.print(":{d}", .{p});

        return buffer.toOwnedSlice(allocator);
    }
};

/// Resolves a relative URI against a base URI per RFC 3986 Section 5.
pub fn resolve(base: Uri, relative_str: []const u8, allocator: Allocator) !Uri {
    var remaining = relative_str;
    var rel_scheme: ?[]const u8 = null;
    var rel_authority: ?[]const u8 = null;
    var rel_path: []const u8 = "";
    var rel_query: ?[]const u8 = null;
    var rel_fragment: ?[]const u8 = null;

    if (mem.indexOf(u8, remaining, "://")) |scheme_end| {
        rel_scheme = remaining[0..scheme_end];
        remaining = remaining[scheme_end + 3 ..];

        if (mem.indexOf(u8, remaining, "/")) |path_start| {
            rel_authority = remaining[0..path_start];
            remaining = remaining[path_start..];
        } else {
            rel_authority = remaining;
            remaining = "";
        }
    }

    if (mem.indexOf(u8, remaining, "#")) |frag_start| {
        rel_fragment = remaining[frag_start + 1 ..];
        remaining = remaining[0..frag_start];
    }

    if (mem.indexOf(u8, remaining, "?")) |query_start| {
        rel_query = remaining[query_start + 1 ..];
        remaining = remaining[0..query_start];
    }

    if (remaining.len > 0 and remaining[0] == '/') {
        rel_path = remaining;
    } else if (remaining.len > 0) {
        rel_path = remaining;
    } else {
        rel_path = "";
    }

    if (rel_scheme) |scheme| {
        return Uri{
            .scheme = scheme,
            .host = rel_authority,
            .path = try normalizePath(rel_path, allocator),
            .query = rel_query,
            .fragment = rel_fragment,
            .raw = relative_str,
        };
    }

    if (rel_authority) |auth| {
        return Uri{
            .scheme = base.scheme,
            .host = auth,
            .path = try normalizePath(rel_path, allocator),
            .query = rel_query,
            .fragment = rel_fragment,
            .raw = relative_str,
        };
    }

    if (rel_path.len == 0) {
        const merged_path = base.path;
        if (rel_query) |q| {
            return Uri{
                .scheme = base.scheme,
                .host = base.host,
                .port = base.port,
                .path = merged_path,
                .query = q,
                .fragment = rel_fragment,
                .raw = relative_str,
            };
        }
        return Uri{
            .scheme = base.scheme,
            .host = base.host,
            .port = base.port,
            .path = merged_path,
            .query = base.query,
            .fragment = rel_fragment,
            .raw = relative_str,
        };
    }

    var merged_path: []const u8 = undefined;
    var needs_free = false;
    if (std.mem.startsWith(u8, rel_path, "/")) {
        merged_path = rel_path;
    } else {
        needs_free = true;
        if (base.host != null) {
            if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |last_slash| {
                merged_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base.path[0 .. last_slash + 1], rel_path });
            } else {
                merged_path = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
            }
        } else {
            if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |last_slash| {
                merged_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base.path[0 .. last_slash + 1], rel_path });
            } else {
                merged_path = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
            }
        }
    }

    // Prevent memory leak: free merged_path if normalizePath fails
    errdefer if (needs_free) allocator.free(merged_path);

    const normalized = try normalizePath(merged_path, allocator);
    if (needs_free) allocator.free(merged_path);

    return Uri{
        .scheme = base.scheme,
        .host = base.host,
        .port = base.port,
        .path = normalized,
        .query = rel_query,
        .fragment = rel_fragment,
        .raw = relative_str,
    };
}

/// Normalizes a URI path by resolving . and .. segments and removing duplicate slashes.
pub fn normalizePath(path: []const u8, allocator: Allocator) ![]const u8 {
    var components = std.ArrayList([]const u8).empty;
    defer components.deinit(allocator);

    var remaining = path;
    while (remaining.len > 0) {
        if (std.mem.startsWith(u8, remaining, "/")) {
            remaining = remaining[1..];
        }
        var end: usize = 0;
        while (end < remaining.len and remaining[end] != '/') : (end += 1) {}
        const component = remaining[0..end];
        remaining = if (end < remaining.len) remaining[end + 1 ..] else remaining[end..];

        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
            continue;
        }
        if (component.len == 0) continue;
        try components.append(allocator, component);
    }

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    try result.append(allocator, '/');
    for (components.items, 0..) |comp, i| {
        try result.appendSlice(allocator, comp);
        if (i < components.items.len - 1) {
            try result.append(allocator, '/');
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Percent-encodes a string for URI inclusion.
/// Delegates to the canonical PercentEncoding implementation.
pub const encode = PercentEncoding.encode;

/// Decodes a percent-encoded string.
/// Delegates to the canonical PercentEncoding implementation.
pub const decode = PercentEncoding.decode;

test "URI parsing basic" {
    const uri = try Uri.parse("http://httpbun.com/path");
    try std.testing.expectEqualStrings("http", uri.scheme.?);
    try std.testing.expectEqualStrings("httpbun.com", uri.host.?);
    try std.testing.expectEqualStrings("/path", uri.path);
}

test "URI parsing with port" {
    const uri = try Uri.parse("http://localhost:8080/api");
    try std.testing.expectEqualStrings("localhost", uri.host.?);
    try std.testing.expectEqual(@as(u16, 8080), uri.port.?);
}

test "URI parsing with query and fragment" {
    const uri = try Uri.parse("http://httpbun.com/search?q=test#results");
    try std.testing.expectEqualStrings("q=test", uri.query.?);
    try std.testing.expectEqualStrings("results", uri.fragment.?);
}

test "URI effective port" {
    const https = try Uri.parse("https://httpbun.com/");
    try std.testing.expectEqual(@as(u16, 443), https.effectivePort());

    const http = try Uri.parse("http://httpbun.com/");
    try std.testing.expectEqual(@as(u16, 80), http.effectivePort());
}

test "URI TLS detection" {
    const https = try Uri.parse("https://httpbun.com/");
    try std.testing.expect(https.isTLS());

    const http = try Uri.parse("http://httpbun.com/");
    try std.testing.expect(!http.isTLS());
}

test "URI resolve relative path" {
    const base = try Uri.parse("http://example.com/a/b/c");
    const resolved = try resolve(base, "d", std.testing.allocator);
    defer std.testing.allocator.free(resolved.path);
    try std.testing.expectEqualStrings("/a/b/d", resolved.path);
}

test "URI resolve absolute path" {
    const base = try Uri.parse("http://example.com/a/b/c");
    const resolved = try resolve(base, "/x/y", std.testing.allocator);
    defer std.testing.allocator.free(resolved.path);
    try std.testing.expectEqualStrings("/x/y", resolved.path);
}

test "URI resolve with scheme" {
    const base = try Uri.parse("http://example.com/a/b/c");
    const resolved = try resolve(base, "https://other.com/x", std.testing.allocator);
    defer std.testing.allocator.free(resolved.path);
    try std.testing.expectEqualStrings("https", resolved.scheme.?);
    try std.testing.expectEqualStrings("other.com", resolved.host.?);
}

test "normalizePath basic" {
    const result = try normalizePath("/a/b/../c", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/a/c", result);
}

test "normalizePath double dots" {
    const result = try normalizePath("/a/b/c/../../d", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/a/d", result);
}

test "normalizePath remove dots" {
    const result = try normalizePath("/a/./b/./c", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/a/b/c", result);
}

test "normalizePath empty" {
    const result = try normalizePath("", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/", result);
}

test "Percent encoding" {
    const allocator = std.testing.allocator;

    const encoded = try encode(allocator, "hello world");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world", encoded);
}

test "Percent decoding" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
}
