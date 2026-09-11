//! SOCKS4/4a proxy client — CONNECT method over TCP.
//!
//! Implements the de-facto SOCKS version 4 protocol (no RFC): request,
//! IPv4 destination, NUL-terminated USERID, and 8-byte reply. SOCKS4a
//! extends it with remote DNS: destinations that are not IPv4 literals
//! are sent as `0.0.0.x` plus a NUL-terminated hostname so the proxy
//! resolves them (same delegation idea as SOCKS5h).
//!
//! There is no authentication: USERID is informational only. IPv6 has no
//! representation and fails loudly with `AddressTypeUnsupported` instead
//! of being downgraded.

const std = @import("std");
const tcp_mod = @import("../sockets/tcp.zig");
const address_mod = @import("address.zig");
const resolve_mod = @import("resolve.zig");

pub const Error = error{
    ProxyConnectFailed,
    ProxyRequestRejected,
    ProxyIdentdFailed,
    ProxyUserIdMismatch,
    AddressTypeUnsupported,
    ProtocolViolation,
    OutOfMemory,
};

/// SOCKS4a marker IP: 0.0.0.0 is invalid, 0.0.0.1 signals the extension.
const ext_marker: u32 = 0x00000001;

/// Performs SOCKS4/4a handshake + CONNECT through `proxyHost:proxyPort`.
/// IPv4 literals use plain SOCKS4; anything else uses the 4a hostname
/// extension (the name is sent unresolved). Returns a Socket tunneled to
/// `destHost:destPort` ready for app traffic.
pub fn connect(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    userId: ?[]const u8,
) !tcp_mod.Socket {
    return connectInternal(io, proxyHost, proxyPort, destHost, destPort, userId, false);
}

/// Connects with stream-backed socket handle (required for TLS encapsulation on Windows).
pub fn connectStream(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    userId: ?[]const u8,
) !tcp_mod.Socket {
    return connectInternal(io, proxyHost, proxyPort, destHost, destPort, userId, true);
}

fn connectInternal(
    io: std.Io,
    proxyHost: []const u8,
    proxyPort: u16,
    destHost: []const u8,
    destPort: u16,
    userId: ?[]const u8,
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

    const id = userId orelse "";
    if (id.len > 255) return Error.ProtocolViolation;
    if (std.mem.indexOfScalar(u8, id, 0) != null) return Error.ProtocolViolation;

    // VER=4 CMD=1(CONNECT) PORT(2) IP(4) USERID NUL [HOST NUL]
    var req: [8 + 256 + 256]u8 = undefined;
    var pos: usize = 0;
    req[pos] = 0x04;
    pos += 1;
    req[pos] = 0x01;
    pos += 1;
    std.mem.writeInt(u16, req[pos..][0..2], destPort, .big);
    pos += 2;
    if (parseIp4(destHost)) |ip| {
        std.mem.writeInt(u32, req[pos..][0..4], ip, .big);
        pos += 4;
    } else {
        if (looksLikeIpv6(destHost)) return Error.AddressTypeUnsupported;
        if (destHost.len == 0 or destHost.len > 255) return Error.AddressTypeUnsupported;
        if (std.mem.indexOfScalar(u8, destHost, 0) != null) return Error.AddressTypeUnsupported;
        std.mem.writeInt(u32, req[pos..][0..4], ext_marker, .big);
        pos += 4;
    }
    @memcpy(req[pos..][0..id.len], id);
    pos += id.len;
    req[pos] = 0;
    pos += 1;
    const use_ext = parseIp4(destHost) == null;
    if (use_ext) {
        @memcpy(req[pos..][0..destHost.len], destHost);
        pos += destHost.len;
        req[pos] = 0;
        pos += 1;
    }
    sock.writeAll(req[0..pos]) catch return Error.ProtocolViolation;

    // Reply: VN(0) CD STATUS(2) PORT(2) IP(4)
    var rep: [8]u8 = undefined;
    _ = readExact(&sock, &rep) catch return Error.ProtocolViolation;
    if (rep[0] != 0x00) return Error.ProtocolViolation;
    switch (rep[1]) {
        0x5A => return sock, // granted
        0x5B => return Error.ProxyRequestRejected,
        0x5C => return Error.ProxyIdentdFailed,
        0x5D => return Error.ProxyUserIdMismatch,
        else => return Error.ProtocolViolation,
    }
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

// In-process mock SOCKS4/4a server for deterministic offline testing

pub const MockSocks4Server = struct {
    listener: tcp_mod.Listener,
    port: u16,
    replyCode: u8 = 0x5A,
    recordedIp: u32 = 0,
    recordedPort: u16 = 0,
    recordedUserIdLen: usize = 0,
    recordedUserId: [256]u8 = undefined,
    recordedHostLen: usize = 0,
    recordedHost: [256]u8 = undefined,
    sawExtension: bool = false,
    thread: ?std.Thread = null,
    io: std.Io,

    pub fn start(io: std.Io, replyCode: u8) !*MockSocks4Server {
        const a = std.testing.allocator;
        const server = try a.create(MockSocks4Server);
        errdefer a.destroy(server);

        const listener = try tcp_mod.Listener.bind(io, 0);
        server.* = .{
            .listener = listener,
            .port = listener.localPort(),
            .replyCode = replyCode,
            .thread = null,
            .io = io,
        };

        server.thread = try std.Thread.spawn(.{}, runServer, .{server});
        return server;
    }

    pub fn deinit(self: *MockSocks4Server) void {
        // Wake a blocked accept with a dummy connection first (Windows AFD
        // reports INVALID_HANDLE when closing a listening socket out from
        // under a pending accept); the woken server sees EOF and exits.
        if (tcp_mod.connect(self.io, "127.0.0.1", self.port)) |s| {
            var dummy = s;
            dummy.close();
        } else |_| {}
        self.listener.close(self.io);
        if (self.thread) |*t| t.join();
        std.testing.allocator.destroy(self);
    }

    fn readByte(conn: *tcp_mod.Socket) ?u8 {
        var b: [1]u8 = undefined;
        _ = readExact(conn, &b) catch return null;
        return b[0];
    }

    fn runServer(self: *MockSocks4Server) void {
        var conn = self.listener.accept(self.io) catch return;
        defer conn.close();

        // VER CMD PORT(2) IP(4)
        var head: [8]u8 = undefined;
        _ = readExact(&conn, &head) catch return;
        if (head[0] != 0x04 or head[1] != 0x01) return;
        self.recordedPort = std.mem.readInt(u16, head[2..4], .big);
        self.recordedIp = std.mem.readInt(u32, head[4..8], .big);

        // USERID NUL
        var ulen: usize = 0;
        while (ulen < self.recordedUserId.len) {
            const b = readByte(&conn) orelse return;
            if (b == 0) break;
            self.recordedUserId[ulen] = b;
            ulen += 1;
        }
        self.recordedUserIdLen = ulen;

        // 4a extension: marker IP + HOST NUL
        if (self.recordedIp == ext_marker) {
            self.sawExtension = true;
            var hlen: usize = 0;
            while (hlen < self.recordedHost.len) {
                const b = readByte(&conn) orelse return;
                if (b == 0) break;
                self.recordedHost[hlen] = b;
                hlen += 1;
            }
            self.recordedHostLen = hlen;
        }

        const reply = [_]u8{ 0x00, self.replyCode, 0x00, 0x00, 0, 0, 0, 0 };
        conn.writeAll(&reply) catch return;

        if (self.replyCode == 0x5A) {
            var echo_buf: [128]u8 = undefined;
            const n = conn.read(&echo_buf) catch 0;
            if (n > 0) {
                conn.writeAll(echo_buf[0..n]) catch {};
            }
        }
    }
};

test "socks4 ipv4 connect sends ip and userid" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocks4Server.start(ctx.io, 0x5A);
    defer mock.deinit();

    var sock = try connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, "bob");
    defer sock.close();

    try sock.writeAll("hello-socks4");
    var buf: [32]u8 = undefined;
    const n = try sock.read(&buf);
    try std.testing.expectEqualStrings("hello-socks4", buf[0..n]);
    try std.testing.expectEqual(@as(u32, 0x7F000001), mock.recordedIp);
    try std.testing.expectEqual(@as(u16, 8080), mock.recordedPort);
    try std.testing.expectEqualStrings("bob", mock.recordedUserId[0..mock.recordedUserIdLen]);
    try std.testing.expect(!mock.sawExtension);
}

test "socks4a hostname forwarded unresolved" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocks4Server.start(ctx.io, 0x5A);
    defer mock.deinit();

    var sock = try connect(ctx.io, "127.0.0.1", mock.port, "unresolvable-internal-domain.local", 443, null);
    defer sock.close();

    try std.testing.expect(mock.sawExtension);
    try std.testing.expectEqualStrings("unresolvable-internal-domain.local", mock.recordedHost[0..mock.recordedHostLen]);
    try std.testing.expectEqual(@as(u16, 443), mock.recordedPort);
}

test "socks4 reject maps to ProxyRequestRejected" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocks4Server.start(ctx.io, 0x5B);
    defer mock.deinit();

    const res = connect(ctx.io, "127.0.0.1", mock.port, "127.0.0.1", 8080, null);
    try std.testing.expectError(Error.ProxyRequestRejected, res);
}

test "socks4 ipv6 destination is rejected loudly" {
    const IoContext = tcp_mod.IoContext;
    var ctx = try IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var mock = try MockSocks4Server.start(ctx.io, 0x5A);
    defer mock.deinit();

    const res = connect(ctx.io, "127.0.0.1", mock.port, "::1", 80, null);
    try std.testing.expectError(Error.AddressTypeUnsupported, res);
}
