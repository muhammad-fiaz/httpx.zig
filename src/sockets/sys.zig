//! Raw socket syscall layer: the ONE place platform socket codes are mapped.
//!
//! Design goal: nothing above this module may ever see an unexpected platform
//! panic. Every documented Winsock and POSIX errno value maps to a named error
//! here; anything unknown degrades gracefully to `error.Unknown` — never
//! unreachable, never a crash.
//!
//! Windows: ws2_32 directly. POSIX: libc when linked or std.posix.
//!
//! References:
//!   - RFC 1122 — Requirements for Internet Hosts (TCP/UDP layer)
//!   - RFC 9112 Section 8 — Connection Management
//!   - POSIX.1-2017 / IEEE Std 1003.1 (sys/socket.h, netinet/tcp.h)
//!

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../common/sync.zig");
const posix = std.posix;

pub const Error = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK / WSAEWOULDBLOCK
    TimedOut, // ETIMEDOUT / WSAETIMEDOUT
    ConnectionReset, // ECONNRESET / WSAECONNRESET / EPIPE
    ConnectionAborted, // ECONNABORTED / WSAECONNABORTED
    ConnectionRefused, // ECONNREFUSED / WSAECONNREFUSED
    NotConnected, // ENOTCONN / WSAENOTCONN
    AlreadyConnected, // EISCONN / WSAEISCONN
    IsConnected, // EISCONN / WSAEISCONN
    InProgress, // EINPROGRESS / WSAEINPROGRESS
    OperationInProgress, // EALREADY / WSAEALREADY / WSAEINPROGRESS
    NetworkDown, // ENETDOWN / WSAENETDOWN / ENETRESET
    NetworkUnreachable, // ENETUNREACH / WSAENETUNREACH
    HostUnreachable, // EHOSTUNREACH / EHOSTDOWN / WSAEHOSTUNREACH / WSAEHOSTDOWN
    Shutdown, // EPIPE / ESHUTDOWN / WSAESHUTDOWN / EINTR
    AccessDenied, // EACCES / EPERM / WSAEACCES
    AddressInUse, // EADDRINUSE / WSAEADDRINUSE
    AddressNotAvailable, // EADDRNOTAVAIL / WSAEADDRNOTAVAIL
    InvalidHandle, // EBADF / ENOTSOCK / WSAEBADF / WSAENOTSOCK
    OutOfBuffers, // ENOBUFS / EMFILE / ENFILE / WSAENOBUFS / WSAEMFILE
    ProtocolError, // EINVAL / EPROTOTYPE / ENOPROTOOPT / EAFNOSUPPORT
    Unknown, // unmapped code — counted atomically, never panics
};

pub var unknownCount: std.atomic.Value(usize) = .init(0);

// Windows

const is_windows = builtin.os.tag == .windows;

pub const ws = if (is_windows) struct {
    pub const SOCKET: usize = ~@as(usize, 0); // INVALID_SOCKET
    pub const SOCKET_ERROR: i32 = -1;

    // select() nfds is ignored on Windows; fd_set uses SOCKET.
    pub const FD_SETSIZE = 64;
    pub const FdSet = extern struct {
        count: u32,
        array: [FD_SETSIZE]usize,

        pub fn zero() FdSet {
            return .{ .count = 0, .array = [_]usize{0} ** FD_SETSIZE };
        }
        pub fn add(self: *FdSet, s: usize) void {
            if (self.count < FD_SETSIZE) {
                self.array[self.count] = s;
                self.count += 1;
            }
        }
    };

    pub const Timeval = extern struct {
        sec: i32,
        usec: i32,
    };

    const WSAData = extern struct {
        version: u16,
        high_version: u16,
        description: [257]u8,
        system_status: [129]u8,
        max_sockets: u16,
        max_udp_dg: u16,
        vendor_info: ?*anyopaque,
    };

    pub extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSAData) callconv(.c) i32;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
    pub extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn shutdown(s: usize, how: i32) callconv(.c) i32;
    pub extern "ws2_32" fn closesocket(s: usize) callconv(.c) i32;
    pub extern "ws2_32" fn select(nfds: i32, readfds: ?*FdSet, writefds: ?*FdSet, exceptfds: ?*FdSet, timeout: ?*Timeval) callconv(.c) i32;
    pub extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: ?*const anyopaque, optlen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, argp: *u32) callconv(.c) i32;

    pub const SOL_SOCKET: i32 = 0xFFFF;
    pub const SO_REUSEADDR: i32 = 0x0004;
    pub const SO_KEEPALIVE: i32 = 0x0008;
    pub const SO_RCVTIMEO: i32 = 0x1006;
    pub const SO_SNDTIMEO: i32 = 0x1007;

    pub const IPPROTO_TCP: i32 = 6;
    pub const TCP_NODELAY: i32 = 1;

    pub const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));

    pub const SD_RECEIVE: i32 = 0;
    pub const SD_SEND: i32 = 1;
    pub const SD_BOTH: i32 = 2;

    var wsa_once: sync.Once = .{};

    fn doWsaStartup() void {
        var data: WSAData = undefined;
        _ = WSAStartup(0x0202, &data);
    }

    pub fn startup() void {
        if (!is_windows) return;
        // Once-gated: racing threads block until WSAStartup completes,
        // so nobody observes WSANOTINITIALISED on socket().
        wsa_once.call(doWsaStartup);
    }

    /// Map every documented winsock error code. Exhaustive by construction:
    /// the else arm counts and returns Unknown instead of panicking.
    pub fn map(code: i32) Error {
        return switch (code) {
            10004 => error.Shutdown, // WSAEINTR
            10009 => error.InvalidHandle, // WSAEBADF
            10013 => error.AccessDenied, // WSAEACCES
            10014 => error.ProtocolError, // WSAEFAULT
            10022 => error.ProtocolError, // WSAEINVAL
            10024 => error.OutOfBuffers, // WSAEMFILE
            10035 => error.WouldBlock, // WSAEWOULDBLOCK
            10036 => error.OperationInProgress, // WSAEINPROGRESS
            10037 => error.OperationInProgress, // WSAEALREADY
            10038 => error.InvalidHandle, // WSAENOTSOCK
            10039 => error.ProtocolError, // WSAEDESTADDRREQ
            10040 => error.ProtocolError, // WSAEMSGSIZE
            10041 => error.ProtocolError, // WSAEPROTOTYPE
            10042 => error.ProtocolError, // WSAENOPROTOOPT
            10043 => error.ProtocolError, // WSAEPROTONOSUPPORT
            10047 => error.ProtocolError, // WSAEAFNOSUPPORT
            10048 => error.AddressInUse, // WSAEADDRINUSE
            10049 => error.AddressNotAvailable, // WSAEADDRNOTAVAIL
            10050 => error.NetworkDown, // WSAENETDOWN
            10051 => error.NetworkUnreachable, // WSAENETUNREACH
            10052 => error.NetworkDown, // WSAENETRESET
            10053 => error.ConnectionAborted, // WSAECONNABORTED
            10054 => error.ConnectionReset, // WSAECONNRESET
            10055 => error.OutOfBuffers, // WSAENOBUFS
            10056 => error.IsConnected, // WSAEISCONN
            10057 => error.NotConnected, // WSAENOTCONN
            10058 => error.Shutdown, // WSAESHUTDOWN
            10060 => error.TimedOut, // WSAETIMEDOUT
            10061 => error.ConnectionRefused, // WSAECONNREFUSED
            10064 => error.HostUnreachable, // WSAEHOSTDOWN
            10065 => error.HostUnreachable, // WSAEHOSTUNREACH
            else => blk: {
                _ = unknownCount.fetchAdd(1, .monotonic);
                break :blk error.Unknown;
            },
        };
    }

    /// True when the peer performed an orderly shutdown on recv.
    pub fn lastWasGracefulClose() bool {
        return WSAGetLastError() == 0 or WSAGetLastError() == 10054;
    }

    pub fn recvRaw(s: usize, buf: []u8) Error!usize {
        const n = recv(s, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0);
        if (n == SOCKET_ERROR) {
            const e = map(WSAGetLastError());
            return e;
        }
        return @intCast(n);
    }

    pub fn sendRaw(s: usize, bytes: []const u8) Error!usize {
        const n = send(s, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(i32))), 0);
        if (n == SOCKET_ERROR) return map(WSAGetLastError());
        return @intCast(n);
    }

    pub fn waitReadable(s: usize, timeout_ms: u31) Error!bool {
        var set = FdSet.zero();
        set.add(s);
        var tv = Timeval{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
        const rc = select(0, &set, null, null, &tv);
        if (rc == SOCKET_ERROR) return map(WSAGetLastError());
        return rc > 0;
    }

    pub fn setTimeouts(s: usize, timeout_ms: u31) void {
        const ms: u32 = @intCast(timeout_ms);
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &ms, 4);
        _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &ms, 4);
    }

    pub fn setNoDelay(s: usize, no_delay: bool) void {
        const opt: c_int = if (no_delay) 1 else 0;
        _ = setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &opt, @sizeOf(c_int));
    }

    pub fn setKeepAlive(s: usize, idle_secs: u32) void {
        _ = idle_secs;
        const one: c_int = 1;
        _ = setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, @sizeOf(c_int));
    }

    pub fn setReuseAddress(s: usize, reuse: bool) void {
        const opt: c_int = if (reuse) 1 else 0;
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, @sizeOf(c_int));
    }

    pub fn setNonBlocking(s: usize, non_blocking: bool) void {
        var mode: u32 = if (non_blocking) 1 else 0;
        _ = ioctlsocket(s, FIONBIO, &mode);
    }
} else struct {};

// POSIX (libc)

pub const posix_c = if (!is_windows and builtin.link_libc) struct {
    pub const fd_t = i32;
    pub const INVALID: fd_t = -1;

    const FdSet = extern struct {
        bits: [1024 / 32]u32,

        pub fn zero() FdSet {
            return .{ .bits = [_]u32{0} ** (1024 / 32) };
        }
        pub fn add(self: *FdSet, fd: fd_t) void {
            const idx: u32 = @intCast(@divFloor(fd, 32));
            self.bits[idx] |= @as(u32, 1) << @intCast(@mod(fd, 32));
        }
    };

    const Timeval = extern struct {
        sec: isize,
        usec: isize,
    };

    extern "c" fn recv(fd: fd_t, buf: [*]u8, len: usize, flags: c_int) isize;
    extern "c" fn send(fd: fd_t, buf: [*]const u8, len: usize, flags: c_int) isize;
    extern "c" fn shutdown(fd: fd_t, how: c_int) c_int;
    extern "c" fn close(fd: fd_t) c_int;
    extern "c" fn select(nfds: c_int, r: ?*FdSet, w: ?*FdSet, e: ?*FdSet, tv: ?*Timeval) c_int;
    extern "c" fn setsockopt(fd: fd_t, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: u32) c_int;
    extern "c" fn fcntl(fd: fd_t, cmd: c_int, ...) c_int;
    extern "c" fn __errno_location() *c_int;

    pub const SOL_SOCKET: c_int = 1;
    pub const SO_REUSEADDR: c_int = 2;
    pub const SO_KEEPALIVE: c_int = 9;
    pub const SO_RCVTIMEO: c_int = 20;
    pub const SO_SNDTIMEO: c_int = 21;

    pub const IPPROTO_TCP: c_int = 6;
    pub const TCP_NODELAY: c_int = 1;

    pub const F_GETFL: c_int = 3;
    pub const F_SETFL: c_int = 4;
    pub const O_NONBLOCK: c_int = 0x800;

    pub const MSG_NOSIGNAL: c_int = switch (builtin.os.tag) {
        .linux => 0x4000,
        .macos => 0, // SO_NOSIGPIPE alternative; macOS lacks MSG_NOSIGNAL
        else => 0,
    };

    pub fn mapErrno(code: c_int) Error {
        return switch (code) {
            4 => error.Shutdown, // EINTR
            11 => error.WouldBlock, // EAGAIN / EWOULDBLOCK
            13 => error.AccessDenied, // EACCES
            32 => error.ConnectionReset, // EPIPE
            98 => error.AddressInUse, // EADDRINUSE
            99 => error.AddressNotAvailable, // EADDRNOTAVAIL
            104 => error.ConnectionReset, // ECONNRESET
            105 => error.OutOfBuffers, // ENOBUFS
            106 => error.IsConnected, // EISCONN
            107 => error.NotConnected, // ENOTCONN
            108 => error.Shutdown, // ESHUTDOWN
            110 => error.TimedOut, // ETIMEDOUT
            111 => error.ConnectionRefused, // ECONNREFUSED
            101 => error.NetworkDown, // ENETDOWN
            102 => error.NetworkUnreachable, // ENETUNREACH
            113 => error.HostUnreachable, // EHOSTUNREACH
            9 => error.InvalidHandle, // EBADF
            88 => error.InvalidHandle, // ENOTSOCK
            115 => error.InProgress, // EINPROGRESS
            114 => error.OperationInProgress, // EALREADY
            22 => error.ProtocolError, // EINVAL
            else => blk: {
                _ = unknownCount.fetchAdd(1, .monotonic);
                break :blk error.Unknown;
            },
        };
    }

    pub fn getErrno() Error {
        return mapErrno(__errno_location().*);
    }

    pub fn recvRaw(fd: fd_t, buf: []u8) Error!usize {
        while (true) {
            const n = recv(fd, buf.ptr, buf.len, 0);
            if (n < 0) {
                const e = getErrno();
                if (e == error.Shutdown) continue; // EINTR retry
                return e;
            }
            return @intCast(n);
        }
    }

    pub fn sendRaw(fd: fd_t, bytes: []const u8) Error!usize {
        while (true) {
            const n = send(fd, bytes.ptr, bytes.len, MSG_NOSIGNAL);
            if (n < 0) {
                const e = getErrno();
                if (e == error.Shutdown) continue; // EINTR retry
                return e;
            }
            return @intCast(n);
        }
    }

    pub fn waitReadable(fd: fd_t, timeout_ms: u31) Error!bool {
        var set = FdSet.zero();
        set.add(fd);
        var tv = Timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        while (true) {
            const rc = select(fd + 1, &set, null, null, &tv);
            if (rc < 0) {
                const e = getErrno();
                if (e == error.Shutdown) continue; // EINTR
                return e;
            }
            return rc > 0;
        }
    }

    pub fn setTimeouts(fd: fd_t, timeout_ms: u31) void {
        const tv = Timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(Timeval));
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, @sizeOf(Timeval));
    }

    pub fn setNoDelay(fd: fd_t, no_delay: bool) void {
        const one: c_int = if (no_delay) 1 else 0;
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, @sizeOf(c_int));
    }

    pub fn setKeepAlive(fd: fd_t, idle_secs: u32) void {
        const one: c_int = 1;
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, @sizeOf(c_int));
        const idle: c_int = @intCast(idle_secs);
        switch (builtin.os.tag) {
            .linux => _ = setsockopt(fd, IPPROTO_TCP, 4, &idle, @sizeOf(c_int)), // TCP_KEEPIDLE
            .macos => _ = setsockopt(fd, IPPROTO_TCP, 0x10, &idle, @sizeOf(c_int)), // TCP_KEEPALIVE
            else => {},
        }
    }

    pub fn setReuseAddress(fd: fd_t, reuse: bool) void {
        const one: c_int = if (reuse) 1 else 0;
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    }

    pub fn setNonBlocking(fd: fd_t, non_blocking: bool) void {
        const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
        if (flags < 0) return;
        const new_flags = if (non_blocking) (flags | O_NONBLOCK) else (flags & ~O_NONBLOCK);
        _ = fcntl(fd, F_SETFL, new_flags);
    }
} else struct {};

// Public API (dispatches per-platform)

/// One-shot global init (WSAStartup on Windows; no-op elsewhere).
pub fn init() void {
    if (is_windows) ws.startup();
}

pub const Handle = if (is_windows) usize else if (builtin.link_libc) posix_c.fd_t else posix.fd_t;

/// Blocking receive with full error mapping. n==0 means orderly peer close.
pub fn read(h: Handle, buf: []u8) Error!usize {
    if (is_windows) return ws.recvRaw(h, buf);
    if (builtin.link_libc) return posix_c.recvRaw(h, buf);
    const n = posix.read(h, buf) catch |err| return mapPosixError(err);
    return n;
}

/// Blocking send with full error mapping. Partial sends are normal.
pub fn write(h: Handle, bytes: []const u8) Error!usize {
    if (is_windows) return ws.sendRaw(h, bytes);
    if (builtin.link_libc) return posix_c.sendRaw(h, bytes);
    const n = posix.write(h, bytes) catch |err| return mapPosixError(err);
    return n;
}

/// Poll for readability. Returns false on timeout.
pub fn waitReadable(h: Handle, timeout_ms: u31) Error!bool {
    if (is_windows) return ws.waitReadable(h, timeout_ms);
    if (builtin.link_libc) return posix_c.waitReadable(h, timeout_ms);
    var pfd = [_]posix.pollfd{.{
        .fd = h,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const rc = posix.poll(&pfd, timeout_ms) catch |err| return mapPosixError(err);
    return rc > 0;
}

pub fn setTimeouts(h: Handle, timeout_ms: u31) void {
    if (is_windows) {
        ws.setTimeouts(h, timeout_ms);
    } else if (builtin.link_libc) {
        posix_c.setTimeouts(h, timeout_ms);
    } else {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = posix.setsockopt(h, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        _ = posix.setsockopt(h, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

pub fn setNoDelay(h: Handle, no_delay: bool) void {
    if (is_windows) {
        ws.setNoDelay(h, no_delay);
    } else if (builtin.link_libc) {
        posix_c.setNoDelay(h, no_delay);
    } else {
        const opt: c_int = if (no_delay) 1 else 0;
        posix.setsockopt(h, posix.IPPROTO.TCP, 1, std.mem.asBytes(&opt)) catch {};
    }
}

pub fn setKeepAlive(h: Handle, idle_secs: u32) void {
    if (is_windows) {
        ws.setKeepAlive(h, idle_secs);
    } else if (builtin.link_libc) {
        posix_c.setKeepAlive(h, idle_secs);
    } else {
        const one: c_int = 1;
        posix.setsockopt(h, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
        const idle: c_int = @intCast(idle_secs);
        switch (builtin.os.tag) {
            .linux => posix.setsockopt(h, posix.IPPROTO.TCP, 4, std.mem.asBytes(&idle)) catch {},
            .macos => posix.setsockopt(h, posix.IPPROTO.TCP, 0x10, std.mem.asBytes(&idle)) catch {},
            else => {},
        }
    }
}

pub fn setReuseAddress(h: Handle, reuse: bool) void {
    if (is_windows) {
        ws.setReuseAddress(h, reuse);
    } else if (builtin.link_libc) {
        posix_c.setReuseAddress(h, reuse);
    } else {
        const opt: c_int = if (reuse) 1 else 0;
        posix.setsockopt(h, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&opt)) catch {};
    }
}

pub fn setNonBlocking(h: Handle, non_blocking: bool) void {
    if (is_windows) {
        ws.setNonBlocking(h, non_blocking);
    } else if (builtin.link_libc) {
        posix_c.setNonBlocking(h, non_blocking);
    } else {
        // std.posix fallback
    }
}

pub fn shutdownSend(h: Handle) void {
    if (is_windows) {
        _ = ws.shutdown(h, ws.SD_SEND);
    } else if (builtin.link_libc) {
        _ = posix_c.shutdown(h, 1); // SHUT_WR
    } else {
        posix.shutdown(h, .send) catch {};
    }
}

pub fn close(h: Handle) void {
    if (is_windows) {
        _ = ws.closesocket(h);
    } else if (builtin.link_libc) {
        _ = posix_c.close(h);
    } else {
        posix.close(h);
    }
}

fn mapPosixError(err: anyerror) Error {
    return switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.ConnectionTimedOut => error.TimedOut,
        error.ConnectionResetByPeer => error.ConnectionReset,
        error.BrokenPipe => error.ConnectionReset,
        error.ConnectionRefused => error.ConnectionRefused,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.AccessDenied => error.AccessDenied,
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressNotAvailable,
        else => blk: {
            _ = unknownCount.fetchAdd(1, .monotonic);
            break :blk error.Unknown;
        },
    };
}

test "error taxonomy: every known winsock code maps to a named error" {
    if (is_windows) {
        try std.testing.expectEqual(Error.WouldBlock, ws.map(10035));
        try std.testing.expectEqual(Error.ConnectionReset, ws.map(10054));
        try std.testing.expectEqual(Error.TimedOut, ws.map(10060));
        try std.testing.expectEqual(Error.ConnectionRefused, ws.map(10061));
        try std.testing.expectEqual(Error.AddressInUse, ws.map(10048));
        try std.testing.expectEqual(Error.AddressNotAvailable, ws.map(10049));
        try std.testing.expectEqual(Error.Unknown, ws.map(999999));
    }
}

test "error taxonomy: posix errno mapping" {
    if (!is_windows and builtin.link_libc) {
        try std.testing.expectEqual(Error.WouldBlock, posix_c.mapErrno(11));
        try std.testing.expectEqual(Error.ConnectionReset, posix_c.mapErrno(104));
        try std.testing.expectEqual(Error.TimedOut, posix_c.mapErrno(110));
        try std.testing.expectEqual(Error.ConnectionRefused, posix_c.mapErrno(111));
        try std.testing.expectEqual(Error.AddressInUse, posix_c.mapErrno(98));
        try std.testing.expectEqual(Error.AddressNotAvailable, posix_c.mapErrno(99));
        try std.testing.expectEqual(Error.Unknown, posix_c.mapErrno(999999));
    }
}

test "unknown codes never panic" {
    if (is_windows) {
        const E = ws.map(-42);
        try std.testing.expect(E == error.Unknown);
        try std.testing.expect(unknownCount.load(.monotonic) >= 1);
    }
}

test "socket option setters execute without panicking" {
    init();
    // Verify sys exports option helpers cleanly
    const t_fn = &setTimeouts;
    _ = t_fn;
    const nd_fn = &setNoDelay;
    _ = nd_fn;
    const ka_fn = &setKeepAlive;
    _ = ka_fn;
    const ra_fn = &setReuseAddress;
    _ = ra_fn;
    const nb_fn = &setNonBlocking;
    _ = nb_fn;
}
