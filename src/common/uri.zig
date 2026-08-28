//! URI/URL parsing shared by client, server, proxy, and router.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Uri = struct {
    scheme: []const u8 = "",
    userinfo: []const u8 = "",
    host: []const u8 = "",
    port: u16 = 0,
    path: []const u8 = "/",
    query: []const u8 = "",
    fragment: []const u8 = "",

    /// Returns the effective port (explicit or default for scheme).
    pub fn effectivePort(self: *const Uri) u16 {
        if (self.port != 0) return self.port;
        return defaultPort(self.scheme);
    }

    pub fn isSecure(self: *const Uri) bool {
        return std.ascii.eqlIgnoreCase(self.scheme, "https") or
            std.ascii.eqlIgnoreCase(self.scheme, "wss") or
            std.ascii.eqlIgnoreCase(self.scheme, "ftps");
    }

    /// Reconstructs the authority portion "host[:port]" with brackets for IPv6.
    pub fn authority(self: *const Uri, buf: []u8) []const u8 {
        const needs_brackets = std.mem.indexOfScalar(u8, self.host, ':') != null;
        if (self.port == 0 or self.port == defaultPort(self.scheme)) {
            if (needs_brackets) return std.fmt.bufPrint(buf, "[{s}]", .{self.host}) catch self.host;
            @memcpy(buf[0..self.host.len], self.host);
            return buf[0..self.host.len];
        }
        if (needs_brackets) return std.fmt.bufPrint(buf, "[{s}]:{d}", .{ self.host, self.port }) catch self.host;
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port }) catch self.host;
    }
};

pub fn defaultPort(scheme: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "ftp")) return 21;
    if (std.ascii.eqlIgnoreCase(scheme, "ftps")) return 990;
    return 0;
}

/// Parses a URI from `input`. The returned Uri references slices of `input`.
pub fn parse(input: []const u8) !Uri {
    var uri = Uri{};
    var rest = input;

    // Fragment
    if (std.mem.indexOfScalar(u8, rest, '#')) |idx| {
        uri.fragment = rest[idx + 1 ..];
        rest = rest[0..idx];
    }

    // Query
    if (std.mem.indexOfScalar(u8, rest, '?')) |idx| {
        uri.query = rest[idx + 1 ..];
        rest = rest[0..idx];
    }

    // Scheme
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        uri.scheme = rest[0..idx];
        rest = rest[idx + 3 ..];
    } else {
        // No scheme — treat entire as path
        uri.path = rest;
        if (uri.path.len == 0) uri.path = "/";
        return uri;
    }

    // Authority vs path
    var authority_end: usize = rest.len;
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
        authority_end = idx;
    }
    const authority_str = rest[0..authority_end];

    // Userinfo
    if (std.mem.lastIndexOfScalar(u8, authority_str, '@')) |idx| {
        uri.userinfo = authority_str[0..idx];
        uri.host = authority_str[idx + 1 ..];
    } else {
        uri.host = authority_str;
    }

    // Port  handle both regular hosts and bracketed IPv6 literals
    if (uri.host.len > 0 and uri.host[0] == '[') {
        // IPv6 literal: [::1]:8080
        if (std.mem.indexOfScalar(u8, uri.host, ']')) |close| {
            const inner = uri.host[1..close]; // strip [ ]
            const after = uri.host[close + 1 ..];
            uri.host = inner;
            if (after.len > 0 and after[0] == ':') {
                uri.port = std.fmt.parseInt(u16, after[1..], 10) catch return error.InvalidUri;
            }
        }
    } else {
        // Regular hostname or bare IPv4
        if (std.mem.lastIndexOfScalar(u8, uri.host, ':')) |idx| {
            uri.port = std.fmt.parseInt(u16, uri.host[idx + 1 ..], 10) catch return error.InvalidUri;
            uri.host = uri.host[0..idx];
        }
    }

    // Path
    uri.path = rest[authority_end..];
    if (uri.path.len == 0) uri.path = "/";

    return uri;
}

fn isIpv6Literal(host: []const u8) bool {
    // IPv6 literals are wrapped in brackets: [::1]:8080
    return host.len > 0 and host[0] == '[';
}

/// Percent-decodes a string in place into `buf`. Returns decoded slice or error if truncated.
pub fn percentDecode(buf: []u8, input: []const u8) ![]const u8 {
    if (input.len > buf.len * 3) return error.BufferTooSmall;
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (out >= buf.len) return error.BufferTooSmall;
        if (input[i] == '%') {
            if (i + 2 >= input.len) {
                buf[out] = input[i];
                out += 1;
                i += 1;
                continue;
            }
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                buf[out] = input[i];
                out += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                buf[out] = input[i];
                out += 1;
                i += 1;
                continue;
            };
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// Checks whether a path contains traversal sequences after decoding.
pub fn hasPathTraversal(decoded_path: []const u8) bool {
    if (decoded_path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, decoded_path, 0) != null) return true;
    if (decoded_path.len >= 2 and decoded_path[1] == ':') return true;
    if (decoded_path.len >= 2 and decoded_path[0] == '\\' and decoded_path[1] == '\\') return true;
    var it = std.mem.splitScalar(u8, decoded_path, '/');
    while (it.next()) |seg| {
        var sub = std.mem.splitScalar(u8, seg, '\\');
        while (sub.next()) |part| {
            if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return true;
            if (part.len >= 2 and part[0] == '.' and part[1] == '.') {
                // catch "..." etc. already, but also "%2e%2e" is decoded before call
            }
        }
    }
    // Also check backslash variants for Windows
    if (std.mem.indexOf(u8, decoded_path, "..\\") != null) return true;
    if (std.mem.indexOf(u8, decoded_path, "\\..") != null) return true;
    return false;
}

// Tests

test "parse full URL" {
    const uri = try parse("https://user:pass@api.example.com:8443/api/users?page=2#results");
    try std.testing.expectEqualStrings("https", uri.scheme);
    try std.testing.expectEqualStrings("api.example.com", uri.host);
    try std.testing.expectEqual(@as(u16, 8443), uri.port);
    try std.testing.expectEqualStrings("/api/users", uri.path);
    try std.testing.expectEqualStrings("page=2", uri.query);
    try std.testing.expectEqualStrings("results", uri.fragment);
    try std.testing.expect(uri.isSecure());
}

test "parse minimal URL" {
    const uri = try parse("http://example.com");
    try std.testing.expectEqualStrings("example.com", uri.host);
    try std.testing.expectEqual(@as(u16, 80), uri.effectivePort());
    try std.testing.expectEqualStrings("/", uri.path);
}

test "parse no scheme" {
    const uri = try parse("/some/path?query=1");
    try std.testing.expectEqualStrings("/some/path", uri.path);
    try std.testing.expectEqualStrings("query=1", uri.query);
}

test "ipv6 literal" {
    const uri = try parse("http://[::1]:8080/test");
    try std.testing.expectEqualStrings("::1", uri.host);
    try std.testing.expectEqual(@as(u16, 8080), uri.port);
}

test "percent decode" {
    var buf: [256]u8 = undefined;
    const result = try percentDecode(&buf, "%48%65%6c%6c%6f%20%57%6f%72%6c%64");
    try std.testing.expectEqualStrings("Hello World", result);
}

test "percent decode passthrough" {
    var buf: [256]u8 = undefined;
    const result = try percentDecode(&buf, "plain-text");
    try std.testing.expectEqualStrings("plain-text", result);
}

test "path traversal detection" {
    try std.testing.expect(hasPathTraversal("../etc/passwd"));
    try std.testing.expect(hasPathTraversal("foo/../../bar"));
    try std.testing.expect(hasPathTraversal("file\x00.txt"));
    try std.testing.expect(hasPathTraversal("\\\\server\\share"));
    try std.testing.expect(hasPathTraversal("C:\\Windows\\system32"));

    try std.testing.expect(!hasPathTraversal("safe/path/file.txt"));
    try std.testing.expect(!hasPathTraversal("relative/file.html"));
}
