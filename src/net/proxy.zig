//! Proxy abstraction shared by every protocol layer.
//!
//! One place maps a URL scheme to a dial strategy so HTTP, WebSocket,
//! FTP, and QUIC callers never re-implement proxy selection:
//!
//!   (none)        -> .direct            resolve locally, connect directly
//!   http://proxy  -> .http_connect      CONNECT tunnel via HTTP proxy
//!   socks5://...  -> .socks5 { remote_dns = false }  local DNS, then proxy
//!   socks5h://... -> .socks5 { remote_dns = true }   proxy resolves DNS
//!
//! SOCKS5H contract: `DialStrategy` carries the hostname UNRESOLVED and
//! `remote_dns` tells socks5.connect to send ATYP=domain. Callers must
//! not consult the local resolver when `needsLocalDns()` is false.

const std = @import("std");

pub const Scheme = enum {
    http,
    https,
    ws,
    wss,
    ftp,
    ftps,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
            .ws => 80,
            .wss => 443,
            .ftp => 21,
            .ftps => 990,
        };
    }
};

pub const ProxyKind = enum {
    direct,
    /// HTTP CONNECT tunnel through an HTTP proxy.
    http_connect,
    socks5,
};

pub const DialStrategy = struct {
    kind: ProxyKind,
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// SOCKS5H flag: delegate destination resolution to the proxy.
    remote_dns: bool = false,

    /// True when the CALLER must not resolve dest_host locally
    /// (SOCKS5H semantics).
    pub fn needsLocalDns(self: *const DialStrategy) bool {
        return switch (self.kind) {
            .direct => true,
            .http_connect => true, // CONNECT target may be host:port; proxy resolves
            .socks5 => !self.remote_dns,
        };
    }

    /// True when the destination host string is forwarded to a proxy that
    /// performs name resolution.
    pub fn proxiesDns(self: *const DialStrategy) bool {
        return self.kind == .socks5 and self.remote_dns;
    }
};

/// Parses a proxy URL of the forms:
///   socks5h://[user:pass@]host:port
///   socks5://[user:pass@]host:port
///   http://host:port
/// Returns null when the text is not a recognized proxy URL.
pub fn parseProxyUrl(url: []const u8) ?struct { kind: ProxyKind, host: []const u8, port: u16, username: ?[]const u8, password: ?[]const u8, remote_dns: bool } {
    if (url.len == 0) return null;

    var kind: ProxyKind = undefined;
    var remote: bool = false;
    var rest: []const u8 = url;

    if (std.mem.startsWith(u8, url, "socks5h://")) {
        kind = .socks5;
        remote = true;
        rest = url["socks5h://".len..];
    } else if (std.mem.startsWith(u8, url, "socks5://")) {
        kind = .socks5;
        rest = url["socks5://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        kind = .http_connect;
        rest = url["http://".len..];
    } else {
        return null;
    }

    // userinfo@host:port
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const creds = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, creds, ':')) |c| {
            username = creds[0..c];
            password = creds[c + 1 ..];
        } else {
            username = creds;
        }
    }

    var host = rest;
    var port: u16 = switch (kind) {
        .http_connect => 80,
        else => 1080,
    };
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // Do not split inside a bracketed IPv6 literal.
        const bracketed = std.mem.indexOfScalar(u8, rest, '[') != null;
        if (!bracketed or std.mem.lastIndexOfScalar(u8, rest, ']') orelse 0 < colon) {
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null;
            host = rest[0..colon];
        }
    }
    // Strip IPv6 brackets for the dial address itself.
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    if (host.len == 0) return null;

    return .{
        .kind = kind,
        .host = host,
        .port = port,
        .username = username,
        .password = password,
        .remote_dns = remote,
    };
}

/// Chooses the dial strategy for a destination URL scheme + optional proxy.
pub fn selectStrategy(
    proxy_url: ?[]const u8,
    dest_scheme: Scheme,
) DialStrategy {
    _ = dest_scheme;
    if (proxy_url) |u| {
        if (parseProxyUrl(u)) |p| {
            return .{
                .kind = p.kind,
                .proxy_host = p.host,
                .proxy_port = p.port,
                .username = p.username,
                .password = p.password,
                .remote_dns = p.remote_dns,
            };
        }
    }
    return .{ .kind = .direct };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse socks5h url carries remote-dns flag" {
    const p = parseProxyUrl("socks5h://u:p@proxy.corp:1080").?;
    try std.testing.expectEqual(ProxyKind.socks5, p.kind);
    try std.testing.expect(p.remote_dns);
    try std.testing.expectEqualStrings("proxy.corp", p.host);
    try std.testing.expectEqual(@as(u16, 1080), p.port);
    try std.testing.expectEqualStrings("u", p.username.?);
    try std.testing.expectEqualStrings("p", p.password.?);
}

test "parse socks5 vs http defaults" {
    const s5 = parseProxyUrl("socks5://[::1]:9050").?;
    try std.testing.expect(!s5.remote_dns);
    try std.testing.expectEqualStrings("::1", s5.host); // brackets stripped

    const hp = parseProxyUrl("http://10.0.0.2:3128").?;
    try std.testing.expectEqual(ProxyKind.http_connect, hp.kind);
    try std.testing.expectEqual(@as(u16, 3128), hp.port);

    try std.testing.expect(parseProxyUrl("ftp://x") == null);
    try std.testing.expect(parseProxyUrl("") == null);
    try std.testing.expect(parseProxyUrl("socks5://") == null); // no host
}

test "strategy dns delegation rules" {
    // Direct always resolves locally.
    var st = selectStrategy(null, .https);
    try std.testing.expect(st.needsLocalDns());
    try std.testing.expect(!st.proxiesDns());

    // SOCKS5 (non-h): local DNS first, then proxy connects to the IP.
    st = selectStrategy("socks5://p:1080", .https);
    try std.testing.expect(st.needsLocalDns());
    try std.testing.expect(!st.proxiesDns());

    // SOCKS5H: NO local DNS; hostname goes to the proxy verbatim.
    st = selectStrategy("socks5h://p:1080", .https);
    try std.testing.expect(!st.needsLocalDns());
    try std.testing.expect(st.proxiesDns());

    // HTTP CONNECT: destination may be a name; proxy resolves it.
    st = selectStrategy("http://p:3128", .https);
    try std.testing.expect(st.kind == .http_connect);
}
