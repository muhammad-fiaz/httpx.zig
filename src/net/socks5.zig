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
const address_mod = @import("address.zig");
const resolve_mod = @import("resolve.zig");

pub const Error = error{
    ProxyConnectFailed,
    ProxyConnectionNotAllowed,
    ProxyNetworkUnreachable,
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
    udpAssociate = 0x03,
};

/// Performs SOCKS5 handshake + CONNECT through `proxyHost:proxyPort`.
/// Returns a Socket tunneled to `destHost:destPort` ready for app traffic.
pub fn connect(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    username: ?[]const u8,
    password: ?[]const u8,
) !tcp_mod.Socket {
    return connectInternal(io, proxyHost, proxyPort, destHost, destPort, username, password, false);
}

/// Connects with stream-backed socket handle (required for TLS encapsulation on Windows).
pub fn connectStream(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    username: ?[]const u8,
    password: ?[]const u8,
) !tcp_mod.Socket {
    return connectInternal(io, proxyHost, proxyPort, destHost, destPort, username, password, true);
}

fn connectInternal(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    username: ?[]const u8,
    password: ?[]const u8,
    isStream: bool,
) !tcp_mod.Socket {
    var probe = address_mod.Address{ .family = .ip4, .port = 0 };
    var sock = if (probe.parseIp(proxyHost)) |parsed| blk: {
        var addr = parsed;
        addr.port = proxyPort;
        if (isStream) {
            break :blk tcp_mod.connectAddressStream(io, &addr) catch return Error.ProxyConnectFailed;
        } else {
            break :blk tcp_mod.connectAddress(io, &addr) catch return Error.ProxyConnectFailed;
        }
    } else |_| blk: {
        const a = std.heap.page_allocator;
        const addrs = (resolve_mod.Resolver.init(a, io)).lookup(proxyHost, .{ .port = proxyPort }) catch return Error.ProxyConnectFailed;
        defer a.free(addrs);
        if (addrs.len == 0) return Error.ProxyConnectFailed;
        for (addrs) |*raddr| {
            if (isStream) {
                if (tcp_mod.connectAddressStream(io, raddr)) |s| break :blk s else |_| {}
            } else {
                if (tcp_mod.connectAddress(io, raddr)) |s| break :blk s else |_| {}
            }
        }
        return Error.ProxyConnectFailed;
    };
    errdefer sock.close();

    // Greeting: VER=5, NMETHODS=1, METHOD=(0x02 or 0x00)
    const want_auth = username != null;
    if (want_auth and password == null) return Error.AuthFailed;

    const greet: [3]u8 = .{ 0x05, 1, if (want_auth) 0x02 else 0x00 };
    try sock.writeAll(&greet);

    var resp: [2]u8 = undefined;
    _ = try readExact(&sock, &resp);
    if (resp[0] != 0x05) return Error.ProtocolViolation;
    if (resp[1] == 0xFF) return Error.NoAcceptableAuth;

    // Username/password subnegotiation (RFC 1929)
    if (resp[1] == 0x02) {
        const u = username orelse return Error.AuthFailed;
        const p = password orelse return Error.AuthFailed;
        if (u.len > 255 or p.len > 255) return Error.AuthFailed;

        var auth_buf: [515]u8 = undefined;
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
        try sock.writeAll(auth_buf[0..pos]);

        var auth_resp: [2]u8 = undefined;
        _ = try readExact(&sock, &auth_resp);
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

    const ip4 = parseIp4(destHost);
    if (ip4) |ip| {
        req[pos] = 0x01; // ATYP IPv4
        pos += 1;
        std.mem.writeInt(u32, req[pos..][0..4], ip, .big);
        pos += 4;
    } else if (looksLikeIpv6(destHost)) {
        if (destHost.len > 255) return Error.AddressTypeUnsupported;
        var v6: [16]u8 = undefined;
        const addr_mod = @import("address.zig");
        var holder = addr_mod.Address{ .family = .ip4, .port = 0 };
        const parsed = holder.parseIp(destHost) catch return Error.AddressTypeUnsupported;
        if (parsed.family != .ip6) return Error.AddressTypeUnsupported;
        v6 = parsed.bytes;
        req[pos] = 0x04; // ATYP IPv6
        pos += 1;
        @memcpy(req[pos..][0..16], v6[0..]);
        pos += 16;
    } else {
        // Domain: this is the SOCKS5H path — the name is sent to the proxy
        // unresolved; callers must NOT resolve it locally first.
        if (destHost.len > 255) return Error.AddressTypeUnsupported;
        req[pos] = 0x03; // ATYP domain
        pos += 1;
        req[pos] = @intCast(destHost.len);
        pos += 1;
        @memcpy(req[pos..][0..destHost.len], destHost);
        pos += destHost.len;
    }
    std.mem.writeInt(u16, req[pos..][0..2], destPort, .big);
    pos += 2;
    try sock.writeAll(req[0..pos]);

    // Reply: VER REP RSV ATYP ADDR(4|16) PORT(2)
    var head: [4]u8 = undefined;
    _ = try readExact(&sock, &head);
    if (head[0] != 0x05) return Error.ProtocolViolation;
    if (head[1] != 0x00) return switch (head[1]) {
        0x01 => Error.ProxyConnectFailed, // general failure
        0x02 => Error.ProxyConnectionNotAllowed, // connection not allowed by ruleset
        0x03 => Error.ProxyNetworkUnreachable, // network unreachable
        0x04 => Error.ProxyHostUnreachable,
        0x05 => Error.ProxyConnectionRefused,
        0x06 => Error.ProxyTtlExpired,
        0x07 => Error.ProxyCommandNotSupported,
        0x08 => Error.ProxyAddressNotSupported,
        else => Error.ProtocolViolation,
    };

    const atyp = head[3];
    var addrLen: usize = switch (atyp) {
        0x01 => 4,
        0x03 => blk: {
            var lb: [1]u8 = undefined;
            _ = try readExact(&sock, &lb);
            break :blk @as(usize, lb[0]);
        },
        0x04 => 16,
        else => return Error.AddressTypeUnsupported,
    };
    // Skip bound address + port
    var skip: [260]u8 = undefined;
    while (addrLen > 0) {
        const chunk = @min(addrLen, skip.len - 2);
        _ = try readExact(&sock, skip[0..chunk]);
        addrLen -= chunk;
    }
    var portb: [2]u8 = undefined;
    _ = try readExact(&sock, &portb);

    return sock;
}

fn readExact(sock: *tcp_mod.Socket, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = sock.read(buf[total..]) catch |e| switch (e) {
            error.ConnectionClosed, error.ConnectionReset => return Error.ProtocolViolation,
            else => return Error.ProtocolViolation,
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

// In-process mock SOCKS5 server for deterministic offline testing

pub const MockSocksServer = struct {
    listener: tcp_mod.Listener,
    port: u16,
    requireAuth: bool = false,
    expectedUser: []const u8 = "alice",
    expectedPass: []const u8 = "secret",
    replyCode: u8 = 0x00,
    recordedAtyp: std.atomic.Value(u8) = .init(0),
    thread: ?std.Thread = null,
    io: std.Io,

    pub fn start(io: std.Io, requireAuth: bool, replyCode: u8) !*MockSocksServer {
        const a = std.testing.allocator;
        const server = try a.create(MockSocksServer);
        errdefer a.destroy(server);

        const listener = try tcp_mod.Listener.bind(io, 0);
        server.* = .{
            .listener = listener,
            .port = listener.localPort(),
            .requireAuth = requireAuth,
            .expectedUser = "alice",
            .expectedPass = "secret",
            .replyCode = replyCode,
            .recordedAtyp = .init(0),
            .thread = null,
            .io = io,
        };

        server.thread = try std.Thread.spawn(.{}, runServer, .{server});
        return server;
    }

    pub fn deinit(self: *MockSocksServer) void {
        self.listener.close(self.io);
        if (self.thread) |*t| t.join();
        std.testing.allocator.destroy(self);
    }

    fn runServer(self: *MockSocksServer) void {
        var conn = self.listener.accept(self.io) catch return;
        defer conn.close();

        // 1. Greeting: [VER=5, NMETHODS, ...methods]
        var greet_head: [2]u8 = undefined;
        _ = readExact(&conn, &greet_head) catch return;
        if (greet_head[0] != 5) return;
        var methods: [255]u8 = undefined;
        const nmethods: usize = greet_head[1];
        _ = readExact(&conn, methods[0..nmethods]) catch return;

        // Choose method
        if (self.requireAuth) {
            conn.writeAll(&[_]u8{ 0x05, 0x02 }) catch return; // user/pass
            // Read subnegotiation: [VER=1, ULEN, USER..., PLEN, PASS...]
            var auth_ver: [2]u8 = undefined;
            _ = readExact(&conn, &auth_ver) catch return;
            const ulen = auth_ver[1];
            var ubuf: [255]u8 = undefined;
            _ = readExact(&conn, ubuf[0..ulen]) catch return;
            var plen_b: [1]u8 = undefined;
            _ = readExact(&conn, &plen_b) catch return;
            const plen = plen_b[0];
            var pbuf: [255]u8 = undefined;
            _ = readExact(&conn, pbuf[0..plen]) catch return;

            const u_ok = std.mem.eql(u8, ubuf[0..ulen], self.expectedUser);
            const p_ok = std.mem.eql(u8, pbuf[0..plen], self.expectedPass);
            if (u_ok and p_ok) {
                conn.writeAll(&[_]u8{ 0x01, 0x00 }) catch return;
            } else {
                conn.writeAll(&[_]u8{ 0x01, 0x01 }) catch return;
                return;
            }
        } else {
            conn.writeAll(&[_]u8{ 0x05, 0x00 }) catch return; // no auth
        }

        // 2. CONNECT request: [VER=5, CMD=1, RSV=0, ATYP, ADDR..., PORT(2)]
        var req_head: [4]u8 = undefined;
        _ = readExact(&conn, &req_head) catch return;
        if (req_head[0] != 5 or req_head[1] != 1) return;
        const atyp = req_head[3];
        self.recordedAtyp.store(atyp, .release);

        switch (atyp) {
            0x01 => { // IPv4: 4 bytes
                var ip4_b: [4]u8 = undefined;
                _ = readExact(&conn, &ip4_b) catch return;
            },
            0x03 => { // Domain: 1 byte len + domain bytes
                var dlen: [1]u8 = undefined;
                _ = readExact(&conn, &dlen) catch return;
                var dbuf: [255]u8 = undefined;
                _ = readExact(&conn, dbuf[0..dlen[0]]) catch return;
            },
            0x04 => { // IPv6: 16 bytes
                var ip6_b: [16]u8 = undefined;
                _ = readExact(&conn, &ip6_b) catch return;
            },
            else => return,
        }
        var port_b: [2]u8 = undefined;
        _ = readExact(&conn, &port_b) catch return;

        // Send reply: [VER=5, REP, RSV=0, ATYP=1, 127.0.0.1, PORT=1080]
        const reply = [_]u8{ 0x05, self.replyCode, 0x00, 0x01, 127, 0, 0, 1, 0x04, 0x38 };
        conn.writeAll(&reply) catch return;

        if (self.replyCode == 0x00) {
            // Echo one message if written
            var echo_buf: [128]u8 = undefined;
            const n = conn.read(&echo_buf) catch 0;
            if (n > 0) {
                conn.writeAll(echo_buf[0..n]) catch {};
            }
        }
    }
};

test "parse dotted quad" {
    try std.testing.expectEqual(@as(?u32, 0x7F000001), parseIp4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x08080808), parseIp4("8.8.8.8"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("example.com"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("999.1.1.1"));
}

test "socks5 mock server no-auth connect and echo" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocksServer.start(ctx.io, false, 0x00);
    defer mock.deinit();

    var sock = try connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, null, null);
    defer sock.close();

    try sock.writeAll("hello-socks5");
    var buf: [32]u8 = undefined;
    const n = try sock.read(&buf);
    try std.testing.expectEqualStrings("hello-socks5", buf[0..n]);
    try std.testing.expectEqual(@as(u8, 0x01), mock.recordedAtyp.load(.acquire));
}

test "socks5h domain name destination sent to proxy" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocksServer.start(ctx.io, false, 0x00);
    defer mock.deinit();

    // SOCKS5H sends unresolvable raw domain directly to proxy
    var sock = try connect(ctx.io, "127.0.0.1", mock.port, "unresolvable-internal-domain.local", 443, null, null);
    defer sock.close();

    // Verify proxy received ATYP=0x03 (domain)
    try std.testing.expectEqual(@as(u8, 0x03), mock.recordedAtyp.load(.acquire));
}

test "socks5 username password authentication success" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocksServer.start(ctx.io, true, 0x00);
    defer mock.deinit();

    var sock = try connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, "alice", "secret");
    defer sock.close();

    try sock.writeAll("auth-ok");
    var buf: [32]u8 = undefined;
    const n = try sock.read(&buf);
    try std.testing.expectEqualStrings("auth-ok", buf[0..n]);
}

test "socks5 wrong password fails with AuthFailed" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocksServer.start(ctx.io, true, 0x00);
    defer mock.deinit();

    const res = connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, "alice", "wrong-password");
    try std.testing.expectError(Error.AuthFailed, res);
}

test "socks5 proxy error reply codes mapped" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    // Test 0x05 Connection Refused
    {
        var mock = try MockSocksServer.start(ctx.io, false, 0x05);
        defer mock.deinit();
        const res = connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, null, null);
        try std.testing.expectError(Error.ProxyConnectionRefused, res);
    }
    // Test 0x04 Host Unreachable
    {
        var mock = try MockSocksServer.start(ctx.io, false, 0x04);
        defer mock.deinit();
        const res = connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, null, null);
        try std.testing.expectError(Error.ProxyHostUnreachable, res);
    }
}
