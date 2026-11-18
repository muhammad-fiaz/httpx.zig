//! Proxy abstraction shared by every protocol layer.
//!
//! One place maps a URL scheme to a dial strategy so HTTP, WebSocket,
//! FTP, and QUIC callers never re-implement proxy selection:
//!
//!   (none)        -> .direct            resolve locally, connect directly
//!   http://proxy  -> .httpConnect       CONNECT tunnel via HTTP proxy
//!   socks5://...  -> .socks5 { remoteDns = false }  local DNS, then proxy
//!   socks5h://... -> .socks5 { remoteDns = true }   proxy resolves DNS
//!
//! SOCKS5H contract: `DialStrategy` carries the hostname UNRESOLVED and
//! `remoteDns` tells socks5.connect to send ATYP=domain. Callers must
//! not consult the local resolver when `needsLocalDns()` is false.

const std = @import("std");
const parseMod = @import("../common/parse.zig");
const z = @import("zigantic");

pub const ProxyKind = enum {
    direct,
    /// HTTP CONNECT tunnel through an HTTP proxy.
    httpConnect,
    socks5,
    /// SOCKS4 (IPv4 literals) / SOCKS4a (remote DNS via hostname extension).
    socks4,
};

const DialStrategySchema = z.objectOf(.{
    .kind = z.enumType(ProxyKind, .{}),
    .proxyHost = z.withDefault(z.string(.{}), ""),
    .proxyPort = z.withDefault(z.integer(u16, .{}), 0),
    .username = z.optional(z.string(.{})),
    .password = z.optional(z.string(.{})),
    .remoteDns = z.withDefault(z.boolean(.{}), false),
}, .{});
pub const DialStrategy = DialStrategySchema.Value;

/// Parsed proxy URL.
const ProxyUrlSchema = z.objectOf(.{
    .kind = z.enumType(ProxyKind, .{}),
    .host = z.string(.{ .min = 1 }),
    .port = z.integer(u16, .{}),
    .username = z.optional(z.string(.{})),
    .password = z.optional(z.string(.{})),
    .remoteDns = z.withDefault(z.boolean(.{}), false),
}, .{});
pub const ProxyUrl = ProxyUrlSchema.Value;

/// True when the CALLER must not resolve destHost locally
/// (SOCKS5H / SOCKS4a semantics).
pub fn needsLocalDns(strategy: DialStrategy) bool {
    return switch (strategy.kind) {
        .direct => true,
        .httpConnect => true, // CONNECT target may be host:port; proxy resolves
        .socks5, .socks4 => !strategy.remoteDns,
    };
}

/// True when the destination host string is forwarded to a proxy that
/// performs name resolution.
pub fn proxiesDns(strategy: DialStrategy) bool {
    return (strategy.kind == .socks5 or strategy.kind == .socks4) and strategy.remoteDns;
}

/// Parses a proxy URL of the forms:
///   socks5h://[user:pass@]host:port
///   socks5://[user:pass@]host:port
///   socks4a://[user@]host:port (remote DNS via hostname extension)
///   socks4://[user@]host:port (IPv4 literals only)
///   http://[user:pass@]host:port (userinfo becomes Proxy-Authorization on CONNECT)
/// Returns null when the text is not a recognized proxy URL.
pub fn parseProxyUrl(url: []const u8) ?ProxyUrl {
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
    } else if (std.mem.startsWith(u8, url, "socks4a://")) {
        kind = .socks4;
        remote = true;
        rest = url["socks4a://".len..];
    } else if (std.mem.startsWith(u8, url, "socks4://")) {
        kind = .socks4;
        rest = url["socks4://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        kind = .httpConnect;
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

    const defaultPort: u16 = switch (kind) {
        .httpConnect => 80,
        else => 1080,
    };
    const auth = parseMod.parseAuthority(rest) orelse return null;
    if (auth.host.len == 0) return null;

    return .{
        .kind = kind,
        .host = auth.host,
        .port = auth.port orelse defaultPort,
        .username = username,
        .password = password,
        .remoteDns = remote,
    };
}

/// Chooses the dial strategy for an optional proxy URL.
pub fn selectStrategy(proxyUrl: ?[]const u8) DialStrategy {
    if (proxyUrl) |u| {
        if (parseProxyUrl(u)) |p| {
            return .{
                .kind = p.kind,
                .proxyHost = p.host,
                .proxyPort = p.port,
                .username = p.username,
                .password = p.password,
                .remoteDns = p.remoteDns,
            };
        }
    }
    return .{ .kind = .direct };
}

// Tests

test "parse socks5h url carries remote-dns flag" {
    const p = parseProxyUrl("socks5h://u:p@proxy.corp:1080").?;
    try std.testing.expectEqual(ProxyKind.socks5, p.kind);
    try std.testing.expect(p.remoteDns);
    try std.testing.expectEqualStrings("proxy.corp", p.host);
    try std.testing.expectEqual(@as(u16, 1080), p.port);
    try std.testing.expectEqualStrings("u", p.username.?);
    try std.testing.expectEqualStrings("p", p.password.?);
}

test "parse socks5 vs http defaults" {
    const s5 = parseProxyUrl("socks5://[::1]:9050").?;
    try std.testing.expect(!s5.remoteDns);
    try std.testing.expectEqualStrings("::1", s5.host); // brackets stripped

    const hp = parseProxyUrl("http://10.0.0.2:3128").?;
    try std.testing.expectEqual(ProxyKind.httpConnect, hp.kind);
    try std.testing.expectEqual(@as(u16, 3128), hp.port);

    try std.testing.expect(parseProxyUrl("ftp://x") == null);
    try std.testing.expect(parseProxyUrl("") == null);
    try std.testing.expect(parseProxyUrl("socks5://") == null); // no host
}

test "strategy dns delegation rules" {
    // Direct always resolves locally.
    var st = selectStrategy(null);
    try std.testing.expect(needsLocalDns(st));
    try std.testing.expect(!proxiesDns(st));

    // SOCKS5 (non-h): local DNS first, then proxy connects to the IP.
    st = selectStrategy("socks5://p:1080");
    try std.testing.expect(needsLocalDns(st));
    try std.testing.expect(!proxiesDns(st));

    // SOCKS5H: NO local DNS; hostname goes to the proxy verbatim.
    st = selectStrategy("socks5h://p:1080");
    try std.testing.expect(!needsLocalDns(st));
    try std.testing.expect(proxiesDns(st));

    // HTTP CONNECT: destination may be a name; proxy resolves it.
    st = selectStrategy("http://p:3128");
    try std.testing.expect(st.kind == .httpConnect);
}

test "parse socks4 and socks4a urls" {
    const s4 = parseProxyUrl("socks4://bob@10.0.0.2:1080").?;
    try std.testing.expectEqual(ProxyKind.socks4, s4.kind);
    try std.testing.expect(!s4.remoteDns);
    try std.testing.expectEqualStrings("10.0.0.2", s4.host);
    try std.testing.expectEqual(@as(u16, 1080), s4.port);
    try std.testing.expectEqualStrings("bob", s4.username.?);

    const s4a = parseProxyUrl("socks4a://10.0.0.2").?;
    try std.testing.expectEqual(ProxyKind.socks4, s4a.kind);
    try std.testing.expect(s4a.remoteDns);
    try std.testing.expectEqual(@as(u16, 1080), s4a.port);

    var st = selectStrategy("socks4://p:1080");
    try std.testing.expect(st.kind == .socks4);
    try std.testing.expect(needsLocalDns(st));
    try std.testing.expect(!proxiesDns(st));

    st = selectStrategy("socks4a://p:1080");
    try std.testing.expect(st.kind == .socks4);
    try std.testing.expect(!needsLocalDns(st));
    try std.testing.expect(proxiesDns(st));
}
