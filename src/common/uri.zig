//! URI/URL parsing shared by client, server, proxy, and router.
//!
//! Parses RFC 3986 generic URI syntax into components. Handles
//! hierarchical URIs with authority, path, query, and fragment.
//! Includes percent-encoding/decoding (RFC 3986 Section 2.1) and
//! path-traversal detection for security-sensitive operations.
//!
//! References:
//!   - RFC 3986 — Uniform Resource Identifier (URI): Generic Syntax
//!   - RFC 3986 Section 2.1 — Percent-Encoding
//!   - RFC 3986 Section 2.2 — Reserved Characters
//!   - RFC 3986 Section 3 — URI Components (scheme, authority, path, query)
//!   - RFC 3986 Section 4.1 — Scheme-Based Parsing
//!   - RFC 6874 — IPv6 Zone Identifiers in URIs

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
    ///
    /// Returns `error.NoSpaceLeft` instead of truncating or overflowing when
    /// `buf` cannot hold the result. Callers that build a Host header must not
    /// fall back to a partial authority: that would silently address a
    /// different origin.
    pub fn authority(self: *const Uri, buf: []u8) error{NoSpaceLeft}![]const u8 {
        const needsBrackets = std.mem.indexOfScalar(u8, self.host, ':') != null;
        if (self.port == 0 or self.port == defaultPort(self.scheme)) {
            if (needsBrackets) return std.fmt.bufPrint(buf, "[{s}]", .{self.host});
            if (buf.len < self.host.len) return error.NoSpaceLeft;
            @memcpy(buf[0..self.host.len], self.host);
            return buf[0..self.host.len];
        }
        if (needsBrackets) return std.fmt.bufPrint(buf, "[{s}]:{d}", .{ self.host, self.port });
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port });
    }
};

pub fn defaultPort(scheme: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "ftp")) return 21;
    if (std.ascii.eqlIgnoreCase(scheme, "ftps")) return 990;
    return 0;
}

const parseMod = @import("parse.zig");

pub const QueryIterator = parseMod.QueryIterator;
pub const lookupQuery = parseMod.lookupQuery;

/// Parses a URI from `input`. The returned Uri references slices of `input`.
///
/// Rejects bytes that cannot appear unescaped in a URI (controls, space, DEL)
/// and malformed schemes. Accepting those would let a caller build a request
/// line or Host header from data the wire grammar forbids; the HTTP/1 writer
/// would then reject the request, but failing here keeps the error precise and
/// stops a redirect target from smuggling separators into URL-derived fields.
pub fn parse(input: []const u8) !Uri {
    for (input) |c| {
        if (c <= 0x20 or c == 0x7F) return error.InvalidUri;
    }

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
        const scheme = rest[0..idx];
        if (!validScheme(scheme)) return error.InvalidUri;
        uri.scheme = scheme;
        rest = rest[idx + 3 ..];
    } else {
        // No scheme — treat entire as path
        uri.path = rest;
        if (uri.path.len == 0) uri.path = "/";
        return uri;
    }

    // Authority vs path
    var authorityEnd: usize = rest.len;
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
        authorityEnd = idx;
    }
    const authorityStr = rest[0..authorityEnd];
    if (authorityStr.len == 0) return error.InvalidUri;

    // Userinfo
    var hostAndPort = authorityStr;
    if (std.mem.lastIndexOfScalar(u8, authorityStr, '@')) |idx| {
        uri.userinfo = authorityStr[0..idx];
        hostAndPort = authorityStr[idx + 1 ..];
    }

    const auth = parseMod.parseAuthority(hostAndPort) orelse return error.InvalidUri;
    if (auth.host.len == 0) return error.InvalidUri;
    if (auth.isIpv6) {
        // Validate bracketed literals as actual IPv6 addresses. The generic
        // authority scanner only checks brackets and ports; without this,
        // `[example.com]` is later treated as a DNS hostname after losing its
        // brackets. URI zone identifiers (RFC 6874) remain unsupported here
        // until the URL-to-resolver path can decode and preserve the zone.
        if (!validUriIpv6Literal(auth.host)) return error.InvalidUri;
    } else if (!validRegName(auth.host)) {
        // Keep the generic authority parser permissive for socket-address
        // callers, but URL authorities must obey RFC 3986 reg-name syntax.
        // Percent-encoded names are rejected because URL resolution currently
        // passes the original host through unchanged instead of decoding it.
        return error.InvalidUri;
    }
    uri.host = auth.host;
    if (auth.port) |p| uri.port = p;

    // Path
    uri.path = rest[authorityEnd..];
    if (uri.path.len == 0) uri.path = "/";

    return uri;
}

/// RFC 3986 reg-name = *( unreserved / pct-encoded / sub-delims ).
fn validRegName(host: []const u8) bool {
    if (host.len == 0) return false;
    var i: usize = 0;
    while (i < host.len) {
        const c = host[i];
        if (isUnreservedChar(c)) {
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn isUnreservedChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Validates an IPv6 URI literal using Zig's address parsers. Zig's pure
/// Ip6Address parser accepts dotted IPv4 tails only for IPv4-mapped addresses,
/// so translate the RFC 4291 tail form to two hex groups before validation.
/// URI scope identifiers are rejected here; callers that need interface zones
/// must use the dedicated socket-address API until URL resolution carries the
/// decoded scope end to end.
fn validUriIpv6Literal(text: []const u8) bool {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '%') != null) return false;
    if (std.ascii.startsWithIgnoreCase(text, "::ffff:")) {
        _ = std.Io.net.Ip6Address.parse(text, 0) catch return false;
        return true;
    }
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |lastColon| {
        const tail = text[lastColon + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '.')) |_| {
            const v4 = std.Io.net.Ip4Address.parse(tail, 0) catch return false;
            const prefix = text[0 .. lastColon + 1];
            var converted: [64]u8 = undefined;
            if (prefix.len + 20 > converted.len) return false;
            const suffix = std.fmt.bufPrint(converted[prefix.len..], "{x}:{x}", .{
                (@as(u16, v4.bytes[0]) << 8) | v4.bytes[1],
                (@as(u16, v4.bytes[2]) << 8) | v4.bytes[3],
            }) catch return false;
            @memcpy(converted[0..prefix.len], prefix);
            _ = std.Io.net.Ip6Address.parse(converted[0 .. prefix.len + suffix.len], 0) catch return false;
            return true;
        }
    }
    _ = std.Io.net.Ip6Address.parse(text, 0) catch return false;
    return true;
}

/// RFC 3986 Section 3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
fn validScheme(scheme: []const u8) bool {
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

fn isIpv6Literal(host: []const u8) bool {
    return host.len > 0 and host[0] == '[';
}

/// Percent-decodes a string in place into `buf`. Returns decoded slice or error if truncated.
pub const percentDecode = parseMod.percentDecode;

/// Percent-encodes a string into `buf` (RFC 3986 unreserved set kept as-is).
pub const percentEncode = parseMod.percentEncode;

pub const isUnreserved = parseMod.isUnreservedChar;

/// Percent-encodes into an owned slice in a single pass.
pub const percentEncodeAlloc = parseMod.percentEncodeAlloc;

/// Checks whether a path contains traversal sequences after decoding.
pub fn hasPathTraversal(decodedPath: []const u8) bool {
    if (decodedPath.len == 0) return false;
    if (std.mem.indexOfScalar(u8, decodedPath, 0) != null) return true;
    if (decodedPath.len >= 2 and decodedPath[1] == ':') return true;
    if (decodedPath.len >= 2 and decodedPath[0] == '\\' and decodedPath[1] == '\\') return true;
    var it = std.mem.splitScalar(u8, decodedPath, '/');
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
    if (std.mem.indexOf(u8, decodedPath, "..\\") != null) return true;
    if (std.mem.indexOf(u8, decodedPath, "\\..") != null) return true;
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

test "parse rejects URI-unsafe bytes" {
    // Controls, space, and DEL cannot appear unescaped in a URI. Accepting
    // them would let URL data smuggle separators into the request line.
    try std.testing.expectError(error.InvalidUri, parse("http://example.com/a b"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com/a\r\nHost: evil"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com/a\tb"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com/\x00"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com/\x7f"));
}

test "parse rejects malformed scheme and authority" {
    try std.testing.expectError(error.InvalidUri, parse("1http://example.com/"));
    try std.testing.expectError(error.InvalidUri, parse("ht tp://example.com/"));
    try std.testing.expectError(error.InvalidUri, parse("http:///path"));
    try std.testing.expectError(error.InvalidUri, parse("http://:8080/"));
    // Bare IPv6 literals are not valid authorities (RFC 3986 requires
    // brackets); they must not be mistaken for host:port.
    try std.testing.expectError(error.InvalidUri, parse("http://::1/"));
    try std.testing.expectError(error.InvalidUri, parse("http://[::1/"));
    try std.testing.expectError(error.InvalidUri, parse("http://[example.com]/"));
    try std.testing.expectError(error.InvalidUri, parse("http://[:::1]/"));
    try std.testing.expectError(error.InvalidUri, parse("http://[fe80::1%25eth0]/"));

    // RFC 4291 permits an IPv4 address in the low 32 bits of an IPv6 literal.
    try std.testing.expectEqualStrings("::192.0.2.1", (try parse("http://[::192.0.2.1]/")).host);
    try std.testing.expectEqualStrings("::ffff:192.0.2.1", (try parse("http://[::ffff:192.0.2.1]/")).host);
}

test "parse rejects malformed reg-name hosts before resolution" {
    try std.testing.expectError(error.InvalidUri, parse("http://exa[mple.com/"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com]/"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com\\evil/"));
    try std.testing.expectError(error.InvalidUri, parse("http://example.com%2f.evil/"));
    try std.testing.expectEqualStrings("example.com", (try parse("http://example.com/")).host);
}

test "authority fails instead of truncating" {
    const uri = try parse("https://example.com:8443/path");
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, uri.authority(&small));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("example.com:8443", try uri.authority(&buf));

    const v6 = try parse("https://[2001:db8::1]:8443/path");
    try std.testing.expectEqualStrings("[2001:db8::1]:8443", try v6.authority(&buf));

    // Default ports are omitted.
    const defaulted = try parse("https://example.com:443/path");
    try std.testing.expectEqualStrings("example.com", try defaulted.authority(&buf));
}
