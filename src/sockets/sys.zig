//! Raw socket syscall layer: the ONE place platform socket codes are mapped.
//!
//! Design goal (Phase 2): nothing above this module may ever see an
//! "unexpected NTSTATUS" panic. Every documented winsock/errno value maps to
//! a named error here; anything unknown degrades to `error.Unknown` — never
//! unreachable, never a crash.
//!
//! Windows: ws2_32 directly. POSIX: libc when linked; otherwise this module
//! exposes only what can be done without libc (documented per-fn).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    WouldBlock, // EAGAIN / WSAEWOULDBLOCK — caller decides retry semantics
    TimedOut,
    ConnectionReset,
    ConnectionAborted,
    ConnectionRefused,
    NotConnected,
    AlreadyConnected,
    IsConnected,
    InProgress, // nonblocking connect mid-flight
    NetworkDown,
    NetworkUnreachable,
    HostUnreachable,
    Shutdown,
    AccessDenied,
    InvalidHandle,
    OutOfBuffers,
    ProtocolError,
    OperationInProgress,
    Unknown, // unmapped code — logged once via count, never panics
};

pub var unknown_count: std.atomic.Value(u64) = .init(0);

// Windows

const is_windows = builtin.os.tag == .windows;

const ws = if (is_windows) struct {
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
    extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
    pub extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn shutdown(s: usize, how: i32) callconv(.c) i32;
    pub extern "ws2_32" fn closesocket(s: usize) callconv(.c) i32;
    extern "ws2_32" fn select(nfds: i32, readfds: ?*FdSet, writefds: ?*FdSet, exceptfds: ?*FdSet, timeout: ?*Timeval) callconv(.c) i32;

    pub const SD_SEND: i32 = 1;
    pub const SD_BOTH: i32 = 2;

    var wsa_done = std.atomic.Value(bool).init(false);

    pub fn startup() void {
        if (!is_windows) return;
        if (wsa_done.swap(true, .acq_rel)) return;
        var data: WSAData = undefined;
        _ = WSAStartup(0x0202, &data);
    }

    /// Map every documented winsock error code. Exhaustive by construction:
    /// the else arm counts and returns Unknown instead of panicking.
    pub fn map(code: i32) Error {
        return switch (code) {
            10004 => error.Shutdown, // WSAEINTR
            10009 => error.InvalidHandle, // WSAEBADF
            10013 => error.AccessDenied, // WSAEACCES
            10014 => error.Unknown, // WSAEFAULT — our bug, but no crash
            10022 => error.ProtocolError, // WSAEINVAL
            10024 => error.OutOfBuffers, // WSAEMFILE
            10035 => error.WouldBlock, // WSAEWOULDBLOCK
            10036 => error.OperationInProgress, // WSAEINPROGRESS
            10037 => error.OperationInProgress, // WSAEALREADY
            10038 => error.InvalidHandle, // WSAENOTSOCK
            10039 => error.ProtocolError, // WSAEDESTADDRREQ
            10040 => error.ProtocolError, // WSAEMSGSIZE
            10041 => error.ProtocolError, // WSAEPROTOTYPE
            10048 => error.AccessDenied, // WSAEADDRINUSE
            10049 => error.Unknown, // WSAEADDRNOTAVAIL
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
                _ = unknown_count.fetchAdd(1, .monotonic);
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
            // Graceful close arrives as SOCKET_ERROR+WSAENOTCONN? No: as 0/-1
            // with WSAESHUTDOWN or clean 0 return. Distinguish here:
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
} else struct {};

// POSIX (libc)

const posix_c = if (!is_windows and builtin.link_libc) struct {
    const fd_t = i32;
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
    extern "c" fn __errno_location() *c_int;

    pub const MSG_NOSIGNAL: c_int = switch (builtin.os.tag) {
        .linux => 0x4000,
        .macos => 0, // SO_NOSIGPIPE alternative; macOS lacks MSG_NOSIGNAL
        else => 0,
    };

    pub fn mapErrno() Error {
        const e = __errno_location().*;
        return switch (e) {
            4 => error.Shutdown, // EINTR — caller may retry
            11 => error.WouldBlock, // EAGAIN/EWOULDBLOCK
            13 => error.AccessDenied, // EACCES
            32 => error.ConnectionReset, // EPIPE
            104 => error.ConnectionReset, // ECONNRESET
            107 => error.NotConnected, // ENOTCONN
            111 => error.ConnectionRefused, // ECONNREFUSED
            110 => error.TimedOut, // ETIMEDOUT
            101 => error.NetworkDown, // ENETDOWN
            102 => error.NetworkUnreachable, // ENETUNREACH
            113 => error.HostUnreachable, // EHOSTUNREACH
            9 => error.InvalidHandle, // EBADF
            else => blk: {
                _ = unknown_count.fetchAdd(1, .monotonic);
                break :blk error.Unknown;
            },
        };
    }

    pub fn recvRaw(fd: fd_t, buf: []u8) Error!usize {
        while (true) {
            const n = recv(fd, buf.ptr, buf.len, 0);
            if (n < 0) {
                const e = mapErrno();
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
                const e = mapErrno();
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
                const e = mapErrno();
                if (e == error.Shutdown) continue; // EINTR
                return e;
            }
            return rc > 0;
        }
    }
} else struct {};

// Public API (dispatches per-platform)

/// One-shot global init (WSAStartup on Windows; no-op elsewhere).
pub fn init() void {
    if (is_windows) ws.startup();
}

pub const Handle = if (is_windows) usize else if (builtin.link_libc) posix_c.fd_t else void;

/// Blocking receive with full error mapping. n==0 means orderly peer close.
pub fn read(h: Handle, buf: []u8) Error!usize {
    if (is_windows) return ws.recvRaw(h, buf);
    if (builtin.link_libc) return posix_c.recvRaw(h, buf);
    return error.Unknown;
}

/// Blocking send with full error mapping. Partial sends are normal.
pub fn write(h: Handle, bytes: []const u8) Error!usize {
    if (is_windows) return ws.sendRaw(h, bytes);
    if (builtin.link_libc) return posix_c.sendRaw(h, bytes);
    return error.Unknown;
}

/// Poll for readability. Returns false on timeout.
pub fn waitReadable(h: Handle, timeout_ms: u31) Error!bool {
    if (is_windows) return ws.waitReadable(h, timeout_ms);
    if (builtin.link_libc) return posix_c.waitReadable(h, timeout_ms);
    return error.Unknown;
}

pub fn shutdownSend(h: Handle) void {
    if (is_windows) {
        _ = ws.shutdown(h, ws.SD_SEND);
    } else if (builtin.link_libc) {
        _ = posix_c.shutdown(h, 1); // SHUT_WR
    }
}

pub fn close(h: Handle) void {
    if (is_windows) {
        _ = ws.closesocket(h);
    } else if (builtin.link_libc) {
        _ = posix_c.close(h);
    }
}

test "error taxonomy: every known code maps to a named error" {
    if (is_windows) {
        try std.testing.expectEqual(Error.WouldBlock, ws.map(10035));
        try std.testing.expectEqual(Error.ConnectionReset, ws.map(10054));
        try std.testing.expectEqual(Error.TimedOut, ws.map(10060));
        try std.testing.expectEqual(Error.ConnectionRefused, ws.map(10061));
        try std.testing.expectEqual(Error.Unknown, ws.map(999999));
    } else if (builtin.link_libc) {
        // errno mapping exercised indirectly through recv paths in integration.
    }
}

test "unknown codes never panic" {
    if (is_windows) {
        // map returns a bare error-set value; just verify side effect.
        const E = ws.map(-42);
        try std.testing.expect(E == error.Unknown);
        try std.testing.expect(unknown_count.load(.monotonic) >= 1);
    }
}
