//! Internet connectivity probing.
//!
//! Checks whether an internet connection is available by attempting a TCP
//! connection to well-known, highly-available public endpoints.  The probe
//! deliberately targets port 53 (DNS/TCP) on Cloudflare (1.1.1.1) and Google
//! (8.8.8.8) because:
//!
//!   - These servers are among the most reliable hosts on the internet.
//!   - Port 53/TCP is open and reachable even from networks that block HTTP.
//!   - No TLS handshake or HTTP exchange is needed; a bare TCP connect suffices.
//!   - IPv4 and IPv6 are both probed (1.1.1.1 / 2606:4700:4700::1111).
//!
//! References:
//!   - RFC 7766 — DNS Transport over TCP
//!   - Cloudflare 1.1.1.1 public resolver: https://1.1.1.1
//!   - Google 8.8.8.8 public resolver: https://dns.google

const std = @import("std");
const addressMod = @import("address.zig");

/// Options controlling the connectivity probe.
pub const ConnectivityOptions = struct {
    /// Milliseconds to wait for each TCP connect attempt.
    /// Default is 3 000 ms — fast enough for interactive use, long enough for
    /// slow mobile links.
    timeoutMs: u32 = 3_000,

    /// Maximum number of probe targets to attempt before returning false.
    /// Stops as soon as one succeeds.  Setting 1 is fastest but less reliable.
    maxProbes: u8 = 4,
};

/// Result returned by `checkConnectivity`.
pub const ConnectivityResult = struct {
    /// True when at least one probe endpoint was reachable.
    online: bool,
    /// Address family that succeeded, or null when offline.
    family: ?addressMod.Family,
    /// Latency of the first successful probe in milliseconds.
    latencyMs: ?u32,
    /// The endpoint IP that succeeded, zero-terminated ASCII, or empty.
    endpoint: [46]u8 = (@as([46]u8, @splat(0))),
    endpointLen: u8 = 0,

    /// Slice of the successful endpoint string.
    pub fn endpointStr(self: *const ConnectivityResult) []const u8 {
        return self.endpoint[0..self.endpointLen];
    }
};

/// Well-known public probe endpoints (IP, port, family).
const Probe = struct {
    ip: []const u8,
    port: u16,
    family: addressMod.Family,
};

const probes: []const Probe = &.{
    .{ .ip = "1.1.1.1", .port = 53, .family = .ip4 }, // Cloudflare v4
    .{ .ip = "8.8.8.8", .port = 53, .family = .ip4 }, // Google v4
    .{ .ip = "2606:4700:4700::1111", .port = 53, .family = .ip6 }, // Cloudflare v6
    .{ .ip = "2001:4860:4860::8888", .port = 53, .family = .ip6 }, // Google v6
};

/// Parse a dotted-decimal IPv4 or a colon-hex IPv6 literal into an Address.
fn parseIpLiteral(ip: []const u8, port: u16, family: addressMod.Family) ?addressMod.Address {
    const scratch = addressMod.Address{ .family = family, .port = port };
    var addr = scratch.parseIp(ip) catch return null;
    if (addr.family != family) return null;
    addr.port = port;
    return addr;
}

const clock = @import("../common/clock.zig");

const builtin = @import("builtin");
const isWindows = builtin.os.tag == .windows;

const ws = if (isWindows) struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = ~@as(usize, 0);

    const AF_INET: i32 = 2;
    const AF_INET6: i32 = 23;
    const SOCK_STREAM: i32 = 1;
    const IPPROTO_TCP: i32 = 6;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));

    const sockaddrIn = extern struct {
        family: u16,
        port: u16,
        addr: [4]u8,
        zero: [8]u8 = @splat(0),
    };

    const sockaddrIn6 = extern struct {
        family: u16,
        port: u16,
        flowinfo: u32 = 0,
        addr: [16]u8,
        scopeId: u32 = 0,
    };

    const FD_SETSIZE = 64;
    const FdSet = extern struct {
        count: u32,
        array: [FD_SETSIZE]usize,

        fn zero() FdSet {
            return .{ .count = 0, .array = (@as([FD_SETSIZE]usize, @splat(0))) };
        }
        fn add(self: *FdSet, s: usize) void {
            if (self.count < FD_SETSIZE) {
                self.array[self.count] = s;
                self.count += 1;
            }
        }
        fn contains(self: *const FdSet, s: usize) bool {
            for (self.array[0..self.count]) |elem| {
                if (elem == s) return true;
            }
            return false;
        }
    };

    const Timeval = extern struct {
        sec: i32,
        usec: i32,
    };

    const wsCall: std.lang.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

    const WSAData = extern struct {
        version: u16,
        highVersion: u16,
        description: [257]u8,
        systemStatus: [129]u8,
        maxSockets: u16,
        maxUdpDg: u16,
        vendorInfo: ?*anyopaque,
    };

    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSAData) callconv(wsCall) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(wsCall) i32;
    extern "ws2_32" fn socket(af: i32, sockType: i32, protocol: i32) callconv(wsCall) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: i32) callconv(wsCall) i32;
    extern "ws2_32" fn closesocket(s: usize) callconv(wsCall) i32;
    extern "ws2_32" fn select(nfds: i32, readfds: ?*FdSet, writefds: ?*FdSet, exceptfds: ?*FdSet, timeout: ?*Timeval) callconv(wsCall) i32;
    extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, argp: *u32) callconv(wsCall) i32;

    var wsaStarted: bool = false;
    fn startup() void {
        if (!wsaStarted) {
            var data: WSAData = undefined;
            _ = WSAStartup(0x0202, &data);
            wsaStarted = true;
        }
    }
} else struct {};

const posixSys = if (!isWindows and builtin.link_libc) struct {
    const PollFd = extern struct {
        fd: std.posix.fd_t,
        events: i16,
        revents: i16,
    };

    const POLLOUT: i16 = 0x0004;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;

    const F_GETFL: c_int = switch (builtin.os.tag) {
        .macos => 3,
        else => 3,
    };
    const F_SETFL: c_int = switch (builtin.os.tag) {
        .macos => 4,
        else => 4,
    };
    const O_NONBLOCK: c_int = switch (builtin.os.tag) {
        .macos => 0x0004,
        else => 0x800,
    };

    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn connect(sockfd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn poll(fds: [*c]PollFd, nfds: usize, timeout: c_int) c_int;
    extern "c" fn getsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*anyopaque, optlen: *u32) c_int;
} else struct {};

fn probeOneWindows(io: std.Io, addr: addressMod.Address, timeoutMs: u32) ?u32 {
    ws.startup();
    const af: i32 = if (addr.family == .ip4) ws.AF_INET else ws.AF_INET6;
    const sock = ws.socket(af, ws.SOCK_STREAM, ws.IPPROTO_TCP);
    if (sock == ws.INVALID_SOCKET) return null;
    defer _ = ws.closesocket(sock);

    var mode: u32 = 1;
    _ = ws.ioctlsocket(sock, ws.FIONBIO, &mode);

    const t0 = clock.monotonicMillis(io);

    const connectRc = switch (addr.family) {
        .ip4 => blk: {
            var sa = ws.sockaddrIn{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes[0..4].*,
            };
            break :blk ws.connect(sock, @ptrCast(&sa), @sizeOf(ws.sockaddrIn));
        },
        .ip6 => blk: {
            var sa = ws.sockaddrIn6{
                .family = @intCast(ws.AF_INET6),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes,
                .scopeId = addr.zone,
            };
            break :blk ws.connect(sock, @ptrCast(&sa), @sizeOf(ws.sockaddrIn6));
        },
    };

    if (connectRc != 0) {
        const lastErr = ws.WSAGetLastError();
        // WSAEWOULDBLOCK = 10035, WSAEINPROGRESS = 10036
        if (lastErr != 10035 and lastErr != 10036) return null;

        var writeSet = ws.FdSet.zero();
        writeSet.add(sock);
        var exceptSet = ws.FdSet.zero();
        exceptSet.add(sock);

        const ms = if (timeoutMs == 0) 3000 else timeoutMs;
        var tv = ws.Timeval{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };

        const sel = ws.select(0, null, &writeSet, &exceptSet, &tv);
        if (sel <= 0) return null;

        if (exceptSet.contains(sock)) return null;
        if (!writeSet.contains(sock)) return null;
    }

    const elapsed = clock.monotonicMillis(io) - t0;
    return @intCast(@max(0, elapsed));
}

fn probeOnePosix(io: std.Io, addr: addressMod.Address, timeoutMs: u32) ?u32 {
    const is_ip4 = addr.family == .ip4;
    const af: c_int = if (is_ip4) std.posix.AF.INET else std.posix.AF.INET6;
    const fd = posixSys.socket(af, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (fd < 0) return null;
    defer _ = posixSys.close(fd);

    const flags = posixSys.fcntl(fd, posixSys.F_GETFL, @as(c_int, 0));
    if (flags < 0) return null;
    if (posixSys.fcntl(fd, posixSys.F_SETFL, flags | posixSys.O_NONBLOCK) < 0) return null;

    const t0 = clock.monotonicMillis(io);

    const connectRc = if (is_ip4) blk: {
        var sa = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, addr.port),
            .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, addr.bytes[0..4], .big)),
            .zero = @splat(0),
        };
        break :blk posixSys.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    } else blk: {
        var sa = std.posix.sockaddr.in6{
            .family = std.posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, addr.port),
            .flowinfo = 0,
            .addr = addr.bytes,
            .scope_id = addr.zone,
        };
        break :blk posixSys.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in6));
    };

    if (connectRc != 0) {
        const errnoVal = std.c._errno().*;
        const inProgress = switch (builtin.os.tag) {
            .macos, .ios, .watchos, .tvos, .visionos => (errnoVal == 36 or errnoVal == 35),
            else => (errnoVal == 115 or errnoVal == 11),
        };
        if (!inProgress) return null;

        const ms: c_int = @intCast(if (timeoutMs == 0) 3000 else timeoutMs);
        var pfd = posixSys.PollFd{
            .fd = fd,
            .events = posixSys.POLLOUT,
            .revents = 0,
        };

        const pollRc = posixSys.poll(&pfd, 1, ms);
        if (pollRc <= 0) return null;

        if ((pfd.revents & (posixSys.POLLERR | posixSys.POLLHUP)) != 0) return null;
        if ((pfd.revents & posixSys.POLLOUT) == 0) return null;

        var so_error: c_int = 0;
        var len: u32 = @sizeOf(c_int);
        if (posixSys.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &so_error, &len) != 0) return null;
        if (so_error != 0) return null;
    }

    const elapsed = clock.monotonicMillis(io) - t0;
    return @intCast(@max(0, elapsed));
}

/// Probe a single endpoint. Returns the latency in ms on success, or null.
fn probeOne(io: std.Io, probe: Probe, timeoutMs: u32) ?u32 {
    const addr = parseIpLiteral(probe.ip, probe.port, probe.family) orelse return null;
    if (isWindows) {
        return probeOneWindows(io, addr, timeoutMs);
    } else if (builtin.link_libc) {
        return probeOnePosix(io, addr, timeoutMs);
    } else {
        return null;
    }
}

test "connectivity probe literals reject malformed input" {
    try std.testing.expect(parseIpLiteral("999.1.1.1", 53, .ip4) == null);
    try std.testing.expect(parseIpLiteral("1.2.3", 53, .ip4) == null);
    try std.testing.expect(parseIpLiteral("1.2.3.4.5", 53, .ip4) == null);
    const v4 = parseIpLiteral("1.1.1.1", 53, .ip4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, v4.bytes[0..4]);
    const v6 = parseIpLiteral("2606:4700:4700::1111", 53, .ip6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 53), v6.port);
}

/// Check whether the internet is reachable.
///
/// Tries up to `opts.maxProbes` well-known public endpoints in order,
/// stopping as soon as one succeeds.  Returns a `ConnectivityResult` with
/// `.online = true` and latency information.
///
/// This function is allocation-free and safe to call from any context.
pub fn checkConnectivity(io: std.Io, opts: ConnectivityOptions) ConnectivityResult {
    const limit = @min(opts.maxProbes, @as(u8, @intCast(probes.len)));
    for (probes[0..limit]) |probe| {
        if (probeOne(io, probe, opts.timeoutMs)) |lat| {
            var result = ConnectivityResult{
                .online = true,
                .family = probe.family,
                .latencyMs = lat,
            };
            const epLen = @min(probe.ip.len, result.endpoint.len);
            @memcpy(result.endpoint[0..epLen], probe.ip[0..epLen]);
            result.endpointLen = @intCast(epLen);
            return result;
        }
    }
    return ConnectivityResult{ .online = false, .family = null, .latencyMs = null };
}

/// Convenience wrapper — returns true if any probe succeeded.
pub fn isOnline(io: std.Io) bool {
    return checkConnectivity(io, .{}).online;
}
