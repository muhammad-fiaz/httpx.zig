//! SOCKS5 proxy client (RFC 1928) - CONNECT method over TCP.
//!
//! Implements the SOCKS Protocol Version 5 per RFC 1928: greeting,
//! method negotiation, CONNECT command, and address types (IPv4, domain,
//! IPv6). Supports no-auth (0x00) and username/password auth (RFC 1929).
//!
//! CONNECT-UDP layering for proxied HTTP/3 rides on this tunnel.
//!
//! References:
//!   - RFC 1928 — SOCKS Protocol Version 5
//!   - RFC 1929 — Username/Password Authentication for SOCKS V5

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const tcp_mod = @import("../sockets/tcp.zig");

pub const Error = error{
    ProxyConnectFailed,
    ProxyHostUnreachable,
    ProxyConnectionRefused,
    ProxyTtlExpired,
    ProxyCommandNotSupported,
    ProxyAddressNotSupported,
    AuthFailed,
    NoAcceptableAuth,
    UnsupportedCommand,
    AddressTypeUnsupported,
    ProtocolViolation,
    OutOfMemory,
};

pub const Command = enum(u8) {
    connect = 0x01,
    bind = 0x02,
    udp_associate = 0x03,
};

/// Performs SOCKS5 handshake + CONNECT through `proxy_host:proxy_port`.
/// Returns a Socket tunneled to `dest_host:dest_port` ready for app traffic.
pub fn connect(
    io: std.Io,
    proxy_host: []const u8,
    proxy_port: u16,
    dest_host: []const u8,
    dest_port: u16,
    username: ?[]const u8,
    password: ?[]const u8,
) !tcp_mod.Socket {
    var sock = try tcp_mod.connect(io, proxy_host, proxy_port);
    errdefer sock.close(io);

    // Greeting: VER=5, NMETHODS, METHODS
    const want_auth = username != null;
    if (want_auth and password == null) return Error.AuthFailed;

    var greet: [4]u8 = .{ 0x05, 1, if (want_auth) 0x02 else 0x00, 0 };
    const greet_len: usize = if (want_auth) 3 else 2;
    try sock.writeAll(io, greet[0..greet_len]);

    var resp: [2]u8 = undefined;
    try readExact(io, &sock, &resp);
    if (resp[0] != 0x05) return Error.ProtocolViolation;
    if (resp[1] == 0xFF) return Error.NoAcceptableAuth;

    // Username/password subnegotiation (RFC 1929)
    if (resp[1] == 0x02) {
        const u = username orelse return Error.AuthFailed;
        const p = password orelse return Error.AuthFailed;
        if (u.len > 255 or p.len > 255) return Error.AuthFailed;

        var auth_buf: [512]u8 = undefined;
        var pos: usize = 0;
        auth_buf[pos] = 0x01; // auth version
        pos += 1;
        auth_buf[pos] = @intCast(u.len);
        pos += 1;
        @memcpy(auth_buf[pos..][0..u.len], u);
        pos += u.len;
        auth_buf[pos] = @intCast(p.len);
        pos += 1;
        @memcpy(auth_buf[pos..][0..p.len], p);
        pos += p.len;
        try sock.writeAll(io, auth_buf[0..pos]);

        var auth_resp: [2]u8 = undefined;
        try readExact(io, &sock, &auth_resp);
        if (auth_resp[0] != 0x01) return Error.ProtocolViolation;
        if (auth_resp[1] != 0x00) return Error.AuthFailed;
    } else if (resp[1] != 0x00) {
        return Error.NoAcceptableAuth;
    }

    // CONNECT request
    var req: [262]u8 = undefined;
    var pos: usize = 0;
    req[pos] = 0x05; // VER
    pos += 1;
    req[pos] = @intFromEnum(Command.connect);
    pos += 1;
    req[pos] = 0x00; // RSV
    pos += 1;

    const ip4 = parseIp4(dest_host);
    if (ip4) |ip| {
        req[pos] = 0x01; // ATYP IPv4
        pos += 1;
        std.mem.writeInt(u32, req[pos..][0..4], ip, .big);
        pos += 4;
    } else if (looksLikeIpv6(dest_host)) {
        if (dest_host.len > 255) return Error.AddressTypeUnsupported;
        var v6: [16]u8 = undefined;
        const addr_mod = @import("address.zig");
        var holder = addr_mod.Address{ .family = .ip4, .port = 0 };
        const parsed = holder.parseIp(dest_host) catch return Error.AddressTypeUnsupported;
        if (parsed.family != .ip6) return Error.AddressTypeUnsupported;
        v6 = parsed.bytes;
        req[pos] = 0x04; // ATYP IPv6
        pos += 1;
        @memcpy(req[pos..][0..16], v6[0..]);
        pos += 16;
    } else {
        // Domain: this is the SOCKS5H path — the name is sent to the proxy
        // unresolved; callers must NOT resolve it locally first.
        if (dest_host.len > 255) return Error.AddressTypeUnsupported;
        req[pos] = 0x03; // ATYP domain
        pos += 1;
        req[pos] = @intCast(dest_host.len);
        pos += 1;
        @memcpy(req[pos..][0..dest_host.len], dest_host);
        pos += dest_host.len;
    }
    std.mem.writeInt(u16, req[pos..][0..2], dest_port, .big);
    pos += 2;
    try sock.writeAll(io, req[0..pos]);

    // Reply: VER REP RSV ATYP ADDR(4|16) PORT(2)
    var head: [4]u8 = undefined;
    try readExact(io, &sock, &head);
    if (head[0] != 0x05) return Error.ProtocolViolation;
    if (head[1] != 0x00) return switch (head[1]) {
        0x01 => Error.ProxyConnectFailed, // general failure
        0x02 => Error.AuthFailed, // connection not allowed by ruleset
        0x03 => Error.ProxyConnectFailed, // network unreachable
        0x04 => Error.ProxyHostUnreachable,
        0x05 => Error.ProxyConnectionRefused,
        0x06 => Error.ProxyTtlExpired,
        0x07 => Error.ProxyCommandNotSupported,
        0x08 => Error.ProxyAddressNotSupported,
        else => Error.ProtocolViolation,
    };

    const atyp = head[3];
    var addr_len: usize = switch (atyp) {
        0x01 => 4,
        0x03 => blk: {
            var lb: [1]u8 = undefined;
            _ = try readExact(io, &sock, &lb);
            break :blk @as(usize, lb[0]);
        },
        0x04 => 16,
        else => return Error.AddressTypeUnsupported,
    };
    // Skip bound address + port
    var skip: [260]u8 = undefined;
    while (addr_len > 0) {
        const chunk = @min(addr_len, skip.len - 2);
        _ = try readExact(io, &sock, skip[0..chunk]);
        addr_len -= chunk;
    }
    var portb: [2]u8 = undefined;
    _ = try readExact(io, &sock, &portb);

    return sock;
}

fn readExact(io: std.Io, sock: *tcp_mod.Socket, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = sock.read(io, buf[total..]) catch |e| switch (e) {
            error.ConnectionClosed => {
                return Error.ProtocolViolation;
            },
            else => return e,
        };
        if (n == 0) return Error.ProtocolViolation;
        total += n;
    }
    return total;
}

fn looksLikeIpv6(text: []const u8) bool {
    // Bracketed or raw IPv6 contains a colon; hostnames never do.
    if (text.len == 0) return false;
    if (text[0] == '[') return true;
    return std.mem.indexOfScalar(u8, text, ':') != null;
}

fn parseIp4(text: []const u8) ?u32 {
    var parts: [4]u32 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |p| {
        if (i >= 4) return null;
        parts[i] = std.fmt.parseInt(u32, p, 10) catch return null;
        if (parts[i] > 255) return null;
        i += 1;
    }
    if (i != 4) return null;
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

test "parse dotted quad" {
    try std.testing.expectEqual(@as(?u32, 0x7F000001), parseIp4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x08080808), parseIp4("8.8.8.8"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("example.com"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("999.1.1.1"));
}
