//! Cross-Platform Socket Abstraction for httpx.zig
//!
//! Provides a unified socket interface for TCP networking across platforms:
//!
//! - Windows (Winsock2) and POSIX systems
//! - TCP client and server socket operations
//! - Configurable timeouts and socket options
//! - Reader/Writer interfaces for streaming

const std = @import("std");
const net = @import("compat.zig");
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const address = @import("address.zig");
const any_io = @import("../io/any_io.zig");

const is_windows = builtin.os.tag == .windows;

const winsock = if (is_windows) struct {
    const SOCKET = usize;
    const SOCKET_ERROR: i32 = -1;
    const INVALID_SOCKET: SOCKET = ~@as(usize, 0);

    const WSAEINTR = 10004;
    const WSAEWOULDBLOCK = 10035;
    const WSAEADDRINUSE = 10048;
    const WSAENOBUFS = 10055;
    const WSAENOTCONN = 10057;
    const WSAETIMEDOUT = 10060;
    const WSAECONNREFUSED = 10061;
    const WSAECONNRESET = 10054;

    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*:0]u8,
    };

    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, name: *const posix.sockaddr, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: SOCKET, name: *const posix.sockaddr, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*posix.sockaddr, addrlen: ?*i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: i32, flags: i32, to: ?*const posix.sockaddr, tolen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: i32, flags: i32, from: ?*posix.sockaddr, fromlen: ?*i32) callconv(.winapi) i32;
    extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *posix.sockaddr, namelen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn getpeername(s: SOCKET, name: *posix.sockaddr, namelen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;
    extern "ws2_32" fn select(nfds: i32, readfds: ?*fd_set, writefds: ?*fd_set, exceptfds: ?*fd_set, timeout: ?*posix.timeval) callconv(.winapi) i32;

    const SO_ERROR: i32 = 0x1007;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
    const FD_SETSIZE: u32 = 64;
    const fd_set = extern struct {
        fd_count: u32,
        fd_array: [FD_SETSIZE]usize,
    };
} else struct {};

var winsock_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const INVALID_SOCKET: posix.socket_t = if (is_windows)
    @ptrFromInt(~@as(usize, 0))
else
    -1;

fn toSocketHandle(raw: anytype) posix.socket_t {
    if (@TypeOf(raw) == posix.socket_t) return raw;
    if (@typeInfo(posix.socket_t) == .pointer) {
        const signed_raw: isize = @intCast(raw);
        return @ptrFromInt(@as(usize, @bitCast(signed_raw)));
    }
    return @as(posix.socket_t, @intCast(raw));
}

fn isNegativeResult(rc: anytype) bool {
    if (comptime @typeInfo(@TypeOf(rc)) == .int and @typeInfo(@TypeOf(rc)).int.signedness == .signed) {
        return rc < 0;
    }
    return false;
}

fn toWinsockSocket(sock: posix.socket_t) usize {
    if (@typeInfo(posix.socket_t) == .pointer) {
        return @intFromPtr(sock);
    }
    return @as(usize, @intCast(sock));
}

fn posixSocket(domain: anytype, sock_type: anytype, protocol: anytype) !posix.socket_t {
    if (is_windows) {
        const rc = winsock.socket(@intCast(domain), @intCast(sock_type), @intCast(protocol));
        if (rc == winsock.INVALID_SOCKET) return error.SocketOpenFailed;
        return toSocketHandle(rc);
    }

    const rc = posix.system.socket(domain, sock_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => return toSocketHandle(rc),
        else => return error.SocketOpenFailed,
    }
}

fn posixConnect(sock: posix.socket_t, addr_ptr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
    if (is_windows) {
        const rc = winsock.connect(toWinsockSocket(sock), addr_ptr, @intCast(addr_len));
        if (rc == winsock.SOCKET_ERROR) return error.ConnectFailed;
        return;
    }

    const rc = posix.system.connect(sock, addr_ptr, addr_len);
    if (isNegativeResult(rc)) return error.ConnectFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.ConnectFailed,
    }
}

fn setSocketNonBlocking(sock: posix.socket_t, enable: bool) !void {
    if (is_windows) {
        var mode: u32 = if (enable) 1 else 0;
        const rc = winsock.ioctlsocket(toWinsockSocket(sock), winsock.FIONBIO, &mode);
        if (rc == winsock.SOCKET_ERROR) {
            return error.SocketOptionFailed;
        }
        return;
    }

    const flags_rc = posix.system.fcntl(sock, posix.F.GETFL, @as(usize, 0));
    const flags_err = posix.errno(flags_rc);
    if (flags_err != .SUCCESS) {
        return error.SocketOptionFailed;
    }
    const flags: usize = @intCast(flags_rc);
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const new_flags = if (enable) flags | nonblock else flags & ~nonblock;
    const setfl_rc = posix.system.fcntl(sock, posix.F.SETFL, new_flags);
    if (posix.errno(setfl_rc) != .SUCCESS) {
        return error.SocketOptionFailed;
    }
}

fn waitConnectWritable(sock: posix.socket_t, timeout_ms: u64) !void {
    if (timeout_ms == 0) return;

    if (is_windows) {
        var write_set: winsock.fd_set = .{ .fd_count = 0, .fd_array = undefined };
        var except_set: winsock.fd_set = .{ .fd_count = 0, .fd_array = undefined };
        const handle = toWinsockSocket(sock);
        write_set.fd_array[0] = handle;
        write_set.fd_count = 1;
        except_set.fd_array[0] = handle;
        except_set.fd_count = 1;

        var tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        const rc = winsock.select(0, null, &write_set, &except_set, &tv);
        if (rc == 0) return error.ConnectionTimeout;
        if (rc == winsock.SOCKET_ERROR) return error.ConnectFailed;
        return;
    }

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i32))));
    while (true) {
        const rc = std.posix.poll(&poll_fds, timeout) catch return error.ConnectFailed;
        if (rc == 0) return error.ConnectionTimeout;
        if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
            return error.ConnectFailed;
        }
        return;
    }
}

fn checkConnectCompleted(sock: posix.socket_t) !void {
    var err_code: i32 = 0;
    if (is_windows) {
        var len: i32 = @sizeOf(i32);
        const rc = winsock.getsockopt(
            toWinsockSocket(sock),
            @intCast(posix.SOL.SOCKET),
            winsock.SO_ERROR,
            @ptrCast(&err_code),
            &len,
        );
        if (rc == winsock.SOCKET_ERROR) return error.ConnectFailed;
    } else {
        var len: posix.socklen_t = @sizeOf(i32);
        const rc = posix.system.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code).ptr, &len);
        if (posix.errno(rc) != .SUCCESS) return error.ConnectFailed;
    }

    if (err_code != 0) return error.ConnectFailed;
}

fn posixConnectWithTimeout(sock: posix.socket_t, addr_ptr: *const posix.sockaddr, addr_len: posix.socklen_t, timeout_ms: u64) !void {
    if (timeout_ms == 0) {
        return posixConnect(sock, addr_ptr, addr_len);
    }

    try setSocketNonBlocking(sock, true);
    errdefer setSocketNonBlocking(sock, false) catch {};

    if (is_windows) {
        const rc = winsock.connect(toWinsockSocket(sock), addr_ptr, @intCast(addr_len));
        if (rc == 0) {
            try setSocketNonBlocking(sock, false);
            return;
        }
        const err = winsock.WSAGetLastError();
        if (err != winsock.WSAEWOULDBLOCK) {
            return error.ConnectFailed;
        }
    } else {
        const rc = posix.system.connect(sock, addr_ptr, addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                try setSocketNonBlocking(sock, false);
                return;
            },
            .INPROGRESS, .ALREADY => {},
            else => {
                return error.ConnectFailed;
            },
        }
    }

    try waitConnectWritable(sock, timeout_ms);
    try checkConnectCompleted(sock);
    try setSocketNonBlocking(sock, false);
}

fn posixBind(sock: posix.socket_t, addr_ptr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
    if (is_windows) {
        const rc = winsock.bind(toWinsockSocket(sock), addr_ptr, @intCast(addr_len));
        if (rc == winsock.SOCKET_ERROR) {
            switch (winsock.WSAGetLastError()) {
                winsock.WSAEADDRINUSE => return error.AddressInUse,
                else => return error.BindFailed,
            }
        }
        return;
    }

    const rc = posix.system.bind(sock, addr_ptr, addr_len);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        else => return error.BindFailed,
    }
}

fn posixListen(sock: posix.socket_t, backlog: u31) !void {
    if (is_windows) {
        const rc = winsock.listen(toWinsockSocket(sock), @intCast(backlog));
        if (rc == winsock.SOCKET_ERROR) return error.ListenFailed;
        return;
    }

    const rc = posix.system.listen(sock, @intCast(backlog));
    if (isNegativeResult(rc)) return error.ListenFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.ListenFailed,
    }
}

fn posixAccept(sock: posix.socket_t, addr_ptr: *posix.sockaddr, addr_len: *posix.socklen_t) !posix.socket_t {
    if (is_windows) {
        var raw_len: i32 = @intCast(addr_len.*);
        const rc = winsock.accept(toWinsockSocket(sock), addr_ptr, &raw_len);
        if (rc == winsock.INVALID_SOCKET) return error.AcceptFailed;
        addr_len.* = @intCast(raw_len);
        return toSocketHandle(rc);
    }

    while (true) {
        const rc = posix.system.accept(sock, addr_ptr, addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => return toSocketHandle(rc),
            .INTR => continue,
            else => return error.AcceptFailed,
        }
    }
}

/// Maximum bytes passed to a single `winsock.send()` call.
///
/// Windows Winsock may return WSAEWOULDBLOCK or WSAENOBUFS when a single
/// blocking send exceeds the kernel send buffer (typically 8–64 KB). Capping
/// each send to 64 KB keeps individual calls within the buffer and prevents
/// the upload loop from hanging on large multipart payloads (issue #26).
const MAX_WINSOCK_SEND_CHUNK: usize = 65536;

fn winsockWaitWritable(sock: posix.socket_t) !void {
    var write_set: winsock.fd_set = .{ .fd_count = 0, .fd_array = undefined };
    write_set.fd_array[0] = toWinsockSocket(sock);
    write_set.fd_count = 1;
    // 30-second timeout matches the default client write_ms so that large
    // multipart uploads do not time out prematurely on slow connections.
    var tv = posix.timeval{ .sec = 30, .usec = 0 };
    const rc = winsock.select(0, null, &write_set, null, &tv);
    if (rc == winsock.SOCKET_ERROR) return error.SendFailed;
    if (rc == 0) return error.TimedOut;
}

fn posixSend(sock: posix.socket_t, data: []const u8, flags: u32) !usize {
    if (is_windows) {
        const chunk = data[0..@min(data.len, MAX_WINSOCK_SEND_CHUNK)];
        while (true) {
            const send_len: i32 = std.math.cast(i32, chunk.len) orelse return error.SendFailed;
            const rc = winsock.send(toWinsockSocket(sock), chunk.ptr, send_len, @intCast(flags));
            if (rc == winsock.SOCKET_ERROR) {
                const err = winsock.WSAGetLastError();
                if (err == winsock.WSAEWOULDBLOCK) {
                    try winsockWaitWritable(sock);
                    continue;
                }
                return error.SendFailed;
            }
            return @intCast(rc);
        }
    }

    while (true) {
        const rc = posix.system.sendto(sock, data.ptr, data.len, @intCast(flags | posix.MSG.NOSIGNAL), null, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.SendFailed,
        }
    }
}

fn posixRecv(sock: posix.socket_t, buffer: []u8, flags: u32) !usize {
    if (is_windows) {
        while (true) {
            const recv_len: i32 = std.math.cast(i32, buffer.len) orelse return error.RecvFailed;
            const rc = winsock.recv(toWinsockSocket(sock), buffer.ptr, recv_len, @intCast(flags));
            if (rc == winsock.SOCKET_ERROR) {
                const err = winsock.WSAGetLastError();
                if (err == winsock.WSAEWOULDBLOCK) {
                    var read_set: winsock.fd_set = .{ .fd_count = 0, .fd_array = undefined };
                    read_set.fd_array[0] = toWinsockSocket(sock);
                    read_set.fd_count = 1;
                    var tv = posix.timeval{ .sec = 30, .usec = 0 };
                    const sel_rc = winsock.select(0, &read_set, null, null, &tv);
                    if (sel_rc == winsock.SOCKET_ERROR) {
                        return error.RecvFailed;
                    }
                    if (sel_rc == 0) {
                        return error.TimedOut;
                    }
                    continue;
                }
                if (err == winsock.WSAECONNRESET) {
                    return error.ConnectionResetByPeer;
                }
                return error.RecvFailed;
            }
            return @intCast(rc);
        }
    }

    while (true) {
        const rc = posix.system.recvfrom(sock, buffer.ptr, buffer.len, @intCast(flags), null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => continue,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.RecvFailed,
        }
    }
}

fn posixSendTo(sock: posix.socket_t, data: []const u8, flags: u32, addr_ptr: *const posix.sockaddr, addr_len: posix.socklen_t) !usize {
    if (is_windows) {
        while (true) {
            const send_len: i32 = std.math.cast(i32, data.len) orelse return error.SendFailed;
            const rc = winsock.sendto(toWinsockSocket(sock), data.ptr, send_len, @intCast(flags), addr_ptr, @intCast(addr_len));
            if (rc == winsock.SOCKET_ERROR) {
                const err = winsock.WSAGetLastError();
                if (err == winsock.WSAEWOULDBLOCK) {
                    try winsockWaitWritable(sock);
                    continue;
                }
                return error.SendFailed;
            }
            return @intCast(rc);
        }
    }

    while (true) {
        const rc = posix.system.sendto(sock, data.ptr, data.len, @intCast(flags | posix.MSG.NOSIGNAL), addr_ptr, addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.SendFailed,
        }
    }
}

fn posixShutdown(sock: posix.socket_t, how: c_int) !void {
    if (is_windows) {
        const rc = winsock.shutdown(toWinsockSocket(sock), @intCast(how));
        if (rc == winsock.SOCKET_ERROR) return error.ShutdownFailed;
        return;
    }

    const rc = posix.system.shutdown(sock, how);
    if (isNegativeResult(rc)) return error.ShutdownFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.ShutdownFailed,
    }
}

fn posixSetSockOpt(sock: posix.socket_t, level: i32, optname: u32, value: []const u8) !void {
    if (is_windows) {
        const value_len: i32 = std.math.cast(i32, value.len) orelse return error.SetSockOptFailed;
        const rc = winsock.setsockopt(toWinsockSocket(sock), level, @intCast(optname), value.ptr, value_len);
        if (rc == winsock.SOCKET_ERROR) return error.SetSockOptFailed;
        return;
    }

    const rc = posix.system.setsockopt(sock, level, optname, value.ptr, @intCast(value.len));
    if (isNegativeResult(rc)) return error.SetSockOptFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.SetSockOptFailed,
    }
}

fn posixGetSockName(sock: posix.socket_t, addr_ptr: *posix.sockaddr, addr_len: *posix.socklen_t) !void {
    if (is_windows) {
        var raw_len: i32 = @intCast(addr_len.*);
        const rc = winsock.getsockname(toWinsockSocket(sock), addr_ptr, &raw_len);
        if (rc == winsock.SOCKET_ERROR) return error.GetSockNameFailed;
        addr_len.* = @intCast(raw_len);
        return;
    }

    const rc = posix.system.getsockname(sock, addr_ptr, addr_len);
    if (isNegativeResult(rc)) return error.GetSockNameFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.GetSockNameFailed,
    }
}

fn posixGetPeerName(sock: posix.socket_t, addr_ptr: *posix.sockaddr, addr_len: *posix.socklen_t) !void {
    if (is_windows) {
        var raw_len: i32 = @intCast(addr_len.*);
        const rc = winsock.getpeername(toWinsockSocket(sock), addr_ptr, &raw_len);
        if (rc == winsock.SOCKET_ERROR) return error.GetPeerNameFailed;
        addr_len.* = @intCast(raw_len);
        return;
    }

    const rc = posix.system.getpeername(sock, addr_ptr, addr_len);
    if (isNegativeResult(rc)) return error.GetPeerNameFailed;
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.GetPeerNameFailed,
    }
}

fn posixClose(sock: posix.socket_t) void {
    if (is_windows) {
        _ = winsock.closesocket(toWinsockSocket(sock));
    } else {
        _ = posix.system.close(sock);
    }
}

pub const UdpError = error{
    SendFailed,
    RecvFailed,
};

pub const NetInitError = error{InitializationError};

/// Shutdown direction for a connected TCP socket.
pub const ShutdownMode = enum {
    recv,
    send,
    both,
};

fn toPosixShutdownHow(mode: ShutdownMode) c_int {
    return switch (mode) {
        .recv => 0,
        .send => 1,
        .both => 2,
    };
}

fn tcpNoDelayOption() u32 {
    return switch (builtin.os.tag) {
        .linux,
        .windows,
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .emscripten,
        .serenity,
        => posix.TCP.NODELAY,
        else => 1,
    };
}

/// Initializes the platform networking subsystem.
///
/// On Windows this calls `WSAStartup`; on other platforms it is a no-op.
pub fn init() NetInitError!void {
    if (!is_windows) return;

    if (winsock_initialized.load(.monotonic)) {
        return;
    }

    // Use compare-and-swap to ensure only one thread initializes Winsock.
    const result = winsock_initialized.cmpxchgWeak(false, true, .acq_rel, .monotonic);
    if (result == null) {
        // We won the race — initialize Winsock.
        var wsa_data: winsock.WSADATA = std.mem.zeroes(winsock.WSADATA);
        const version_2_2: u16 = (@as(u16, 2) << 8) | 2;
        if (winsock.WSAStartup(version_2_2, &wsa_data) != 0) {
            winsock_initialized.store(false, .release);
            return error.InitializationError;
        }
    } else {
        // Another thread is initializing — spin until done.
        while (!winsock_initialized.load(.acquire)) {
            std.Thread.yield() catch {};
        }
    }
}

/// Deinitializes the platform networking subsystem.
///
/// On Windows this calls `WSACleanup`; on other platforms it is a no-op.
pub fn deinit() void {
    if (!is_windows) return;
    if (!winsock_initialized.load(.monotonic)) return;
    _ = winsock.WSACleanup();
    winsock_initialized.store(false, .release);
}

/// Adapter that exposes a `std.Io.Reader` backed by a connected `Socket`.
///
/// This is used to integrate with the custom TLS implementation in `tls.zig`.
pub const SocketIoReader = struct {
    socket: *Socket,
    reader: Io.Reader,

    pub fn init(socket: *Socket, buffer: []u8) SocketIoReader {
        return .{
            .socket = socket,
            .reader = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn parent(r: *Io.Reader) *SocketIoReader {
        return @fieldParentPtr("reader", r);
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        var total: usize = 0;
        const max_limit = limit.toInt() orelse std.math.maxInt(usize);

        while (total < max_limit) {
            const max_to_read = @min(r.buffer.len, max_limit - total);
            var iov = [_][]u8{r.buffer[0..max_to_read]};
            const n = readVec(r, &iov) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;

            try w.writeAll(r.buffer[0..n]);
            total += n;
        }

        return total;
    }

    fn discard(r: *Io.Reader, limit: Io.Limit) error{ EndOfStream, ReadFailed }!usize {
        var total: usize = 0;
        const max_limit = limit.toInt() orelse std.math.maxInt(usize);

        while (total < max_limit) {
            const max_to_read = @min(r.buffer.len, max_limit - total);
            var iov = [_][]u8{r.buffer[0..max_to_read]};
            const n = readVec(r, &iov) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        }

        return total;
    }

    fn readVec(r: *Io.Reader, bufs: [][]u8) Io.Reader.Error!usize {
        var iovecs_buffer: [4][]u8 = undefined;
        const dest_n, const data_size = try r.writableVector(&iovecs_buffer, bufs);
        const dest = iovecs_buffer[0..dest_n];
        if (dest.len == 0 or dest[0].len == 0) return 0;

        const p = parent(r);
        const n = p.socket.recv(dest[0]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            @branchHint(.likely);
            r.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn rebase(r: *Io.Reader, _: usize) Io.Reader.RebaseError!void {
        const data = r.buffer[r.seek..r.end];
        @memmove(r.buffer[0..data.len], data);
        r.seek = 0;
        r.end = data.len;
    }

    const vtable: Io.Reader.VTable = .{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
        .rebase = rebase,
    };
};

/// Adapter that exposes a `std.Io.Writer` backed by a connected `Socket`.
///
/// This is used to integrate with the custom TLS implementation in `tls.zig`.
pub const SocketIoWriter = struct {
    socket: *Socket,
    writer: Io.Writer,

    pub fn init(socket: *Socket, buffer: []u8) SocketIoWriter {
        return .{
            .socket = socket,
            .writer = .{
                .vtable = &vtable,
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    fn parent(w: *Io.Writer) *SocketIoWriter {
        return @fieldParentPtr("writer", w);
    }

    fn drain(w: *Io.Writer, bufs: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p = parent(w);
        var total_sent: usize = 0;

        const buffered = w.buffered();
        if (buffered.len > 0) {
            const num = p.socket.send(buffered) catch return error.WriteFailed;
            total_sent += num;
            if (num < buffered.len) return w.consume(total_sent);
        }

        const data_bufs = bufs[0 .. bufs.len - 1];
        for (data_bufs) |bytes| {
            if (bytes.len == 0) continue;
            const num = p.socket.send(bytes) catch return error.WriteFailed;
            total_sent += num;
            if (num < bytes.len) return w.consume(total_sent);
        }

        const pattern = bufs[bufs.len - 1];
        if (pattern.len > 0 and splat > 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                const num = p.socket.send(pattern) catch return error.WriteFailed;
                total_sent += num;
                if (num < pattern.len) return w.consume(total_sent);
            }
        }
        return w.consume(total_sent);
    }

    fn sendFile(w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileAllError!usize {
        const p = parent(w);

        var total: usize = 0;
        const max_limit = limit.toInt() orelse std.math.maxInt(usize);
        while (total < max_limit) {
            const remaining = max_limit - total;
            const chunk_len = @min(w.buffer.len, remaining);
            if (chunk_len == 0) break;

            var vec = [_][]u8{w.buffer[0..chunk_len]};
            const n_read = file_reader.interface.readVec(&vec) catch return error.ReadFailed;
            if (n_read == 0) break;

            p.socket.sendAll(w.buffer[0..n_read]) catch return error.WriteFailed;
            total += n_read;
        }

        return total;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        return std.Io.Writer.defaultFlush(w);
    }

    fn rebase(_: *Io.Writer, _: usize, _: usize) Io.Writer.Error!void {
        // No-op.
    }

    const vtable: Io.Writer.VTable = .{
        .drain = drain,
        .sendFile = sendFile,
        .flush = flush,
        .rebase = rebase,
    };
};

/// TCP socket abstraction with cross-platform support.
pub const Socket = struct {
    handle: posix.socket_t,
    connected: bool = false,

    const Self = @This();
    pub const AcceptResult = struct {
        socket: Socket,
        addr: net.Address,
    };

    /// Creates a new TCP socket.
    pub fn create() !Self {
        return createV4();
    }

    /// Creates a new IPv4 TCP socket.
    pub fn createV4() !Self {
        try init();
        const handle = try posixSocket(posix.AF.INET, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new IPv6 TCP socket.
    pub fn createV6() !Self {
        try init();
        const handle = try posixSocket(posix.AF.INET6, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new TCP socket using the address family of the provided address.
    pub fn createForAddress(addr: net.Address) !Self {
        try init();
        const handle = try posixSocket(addr.any.family, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a socket from an existing handle.
    pub fn fromHandle(handle: posix.socket_t) Self {
        return .{ .handle = handle, .connected = true };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        if (self.isValid()) {
            posixClose(self.handle);
            self.handle = INVALID_SOCKET;
            self.connected = false;
        }
    }

    /// Returns true if the socket handle is valid.
    pub fn isValid(self: *const Self) bool {
        return self.handle != INVALID_SOCKET;
    }

    /// Connects to the specified address.
    pub fn connect(self: *Self, addr: net.Address) !void {
        try self.connectWithTimeout(addr, 0);
    }

    /// Connects to the specified address with a connect-phase timeout in milliseconds.
    /// A timeout of `0` disables the connect timeout and uses a blocking connect.
    pub fn connectWithTimeout(self: *Self, addr: net.Address, timeout_ms: u64) !void {
        try posixConnectWithTimeout(self.handle, &addr.any, addr.getOsSockLen(), timeout_ms);
        self.connected = true;
    }

    /// Resolves and connects to `host:port`.
    pub fn connectHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        try self.connect(addr);
    }

    /// Parses and connects an endpoint like `host:port`.
    pub fn connectEndpoint(self: *Self, endpoint: []const u8, default_port: u16) !void {
        const parsed = try address.parseHostPort(endpoint, default_port);
        try self.connectHost(parsed.host, parsed.port);
    }

    /// Sends data through the socket, returning bytes sent.
    pub fn send(self: *Self, data: []const u8) !usize {
        const n = posixSend(self.handle, data, 0) catch |err| {
            return err;
        };
        return n;
    }

    /// Compatibility alias for stream-style write APIs.
    pub fn write(self: *Self, data: []const u8) !usize {
        return self.send(data);
    }

    /// Sends all data, blocking until complete.
    pub fn sendAll(self: *Self, data: []const u8) !void {
        var sent: usize = 0;
        // Safety limit: prevent infinite loop if send returns 0 repeatedly.
        var zero_count: u8 = 0;
        while (sent < data.len) {
            const n = try self.send(data[sent..]);
            if (n == 0) {
                zero_count += 1;
                if (zero_count >= 3) return error.SendFailed;
            } else {
                zero_count = 0;
            }
            sent += n;
        }
    }

    /// Compatibility alias for stream-style write-all APIs.
    pub fn writeAll(self: *Self, data: []const u8) !void {
        return self.sendAll(data);
    }

    /// Receives data into the buffer, returning bytes received.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        const n = posixRecv(self.handle, buffer, 0) catch |err| {
            return err;
        };
        return n;
    }

    /// Compatibility alias for stream-style read APIs.
    pub fn read(self: *Self, buffer: []u8) !usize {
        return self.recv(buffer);
    }

    /// Sets a socket option.
    pub fn setOption(self: *Self, level: u32, optname: u32, value: []const u8) !void {
        try posixSetSockOpt(self.handle, level, optname, value);
    }

    /// Enables or disables TCP_NODELAY (Nagle's algorithm).
    pub fn setNoDelay(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, tcpNoDelayOption(), std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    pub fn setRecvBufferSize(self: *Self, size: u32) !void {
        const value: i32 = @intCast(size);
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&value));
    }

    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }

    pub fn setSendBufferSize(self: *Self, size: u32) !void {
        const value: i32 = @intCast(size);
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&value));
    }

    /// Enables or disables keep-alive probes.
    pub fn setKeepAlive(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&value));
    }

    /// Sets TCP keepalive idle time (seconds before first probe).
    /// Only meaningful when keep-alive is enabled.
    pub fn setKeepAliveIdle(self: *Self, seconds: u32) !void {
        if (builtin.os.tag == .linux) {
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, std.mem.asBytes(&seconds));
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, 0x101, std.mem.asBytes(&seconds)); // TCP_KEEPALIVE
        } else if (is_windows) {
            // Windows: use SO_KEEPALIVE; idle time is configured via SIO_KEEPALIVE_VALS
            // which requires a struct, not a simple setsockopt. Return an error
            // so callers know this platform doesn't support simple keepalive idle config.
            return error.UnsupportedOperation;
        }
    }

    /// Sets TCP keepalive interval (seconds between probes).
    /// Only meaningful when keep-alive is enabled.
    pub fn setKeepAliveInterval(self: *Self, seconds: u32) !void {
        if (builtin.os.tag == .linux) {
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, std.mem.asBytes(&seconds));
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, 0x102, std.mem.asBytes(&seconds)); // TCP_KEEPINTVL
        } else if (is_windows) {
            return error.UnsupportedOperation;
        }
    }

    /// Sets TCP keepalive probe count (number of probes before declaring dead).
    /// Only meaningful when keep-alive is enabled.
    pub fn setKeepAliveCount(self: *Self, count: u32) !void {
        if (builtin.os.tag == .linux) {
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, std.mem.asBytes(&count));
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
            // macOS: TCP_KEEPCNT = 0x109 (265 decimal)
            try posixSetSockOpt(self.handle, posix.IPPROTO.TCP, 0x109, std.mem.asBytes(&count));
        } else if (is_windows) {
            return error.UnsupportedOperation;
        }
    }

    /// Enables or disables dual-stack mode (IPV6_V6ONLY).
    /// When disabled (v6only=false), an IPv6 socket can accept both IPv4 and IPv6 connections.
    /// When enabled, the socket only handles IPv6 connections.
    pub fn setDualStack(self: *Self, v6only: bool) !void {
        const value: u32 = if (v6only) 1 else 0;
        // IPV6_V6ONLY = 27 on all platforms
        const ipv6_v6only: u32 = 27;
        const ip_proto: u32 = if (is_windows) 41 else posix.IPPROTO.IPV6;
        try posixSetSockOpt(self.handle, ip_proto, ipv6_v6only, std.mem.asBytes(&value));
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }

    /// Enables or disables port reuse (SO_REUSEPORT).
    /// Only supported on Linux and macOS. Returns UnsupportedOperation on other platforms.
    pub fn setReusePort(self: *Self, enable: bool) !void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .ios) {
            return error.UnsupportedOperation;
        }
        const value: u32 = if (enable) 1 else 0;
        const optname: u32 = if (builtin.os.tag == .linux) 15 else posix.SO.REUSEADDR;
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, optname, std.mem.asBytes(&value));
    }

    /// Sets SO_LINGER option on socket.
    pub fn setLinger(self: *Self, onoff: bool, linger_sec: u16) !void {
        const LingerStruct = extern struct {
            l_onoff: c_int,
            l_linger: c_int,
        };
        const l = LingerStruct{
            .l_onoff = if (onoff) 1 else 0,
            .l_linger = @intCast(linger_sec),
        };
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&l));
    }

    /// Binds the socket to an address.
    pub fn bind(self: *Self, addr: net.Address) !void {
        try posixBind(self.handle, &addr.any, addr.getOsSockLen());
    }

    /// Resolves and binds to `host:port`.
    pub fn bindHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        try self.bind(addr);
    }

    /// Starts listening for connections.
    pub fn listen(self: *Self, backlog: u31) !void {
        try posixListen(self.handle, backlog);
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !AcceptResult {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const handle = posixAccept(self.handle, &addr, &addr_len) catch |err| {
            return err;
        };
        return .{
            .socket = Socket.fromHandle(handle),
            .addr = net.Address{ .any = addr },
        };
    }

    /// Shuts down one or both halves of the connection.
    pub fn shutdown(self: *Self, mode: ShutdownMode) !void {
        try posixShutdown(self.handle, toPosixShutdownHow(mode));
    }

    /// Shuts down the receive direction.
    pub fn shutdownRead(self: *Self) !void {
        try self.shutdown(.recv);
    }

    /// Shuts down the send direction.
    pub fn shutdownWrite(self: *Self) !void {
        try self.shutdown(.send);
    }

    /// Shuts down both directions.
    pub fn shutdownBoth(self: *Self) !void {
        try self.shutdown(.both);
    }

    /// Waits up to `timeout_ms` for the socket to become readable (have data
    /// available or a pending connection on a listening socket). Returns true
    /// if the socket is readable, false on timeout.
    pub fn waitReadable(self: *Self, timeout_ms: u32) bool {
        if (is_windows) {
            var read_set: winsock.fd_set = .{ .fd_count = 0, .fd_array = undefined };
            read_set.fd_array[0] = toWinsockSocket(self.handle);
            read_set.fd_count = 1;
            var tv = posix.timeval{
                .sec = @intCast(@divTrunc(@as(u64, timeout_ms), 1000)),
                .usec = @intCast(@mod(@as(u64, timeout_ms), @as(u64, 1000)) * 1000),
            };
            const rc = winsock.select(0, &read_set, null, null, &tv);
            const ready = rc > 0;
            return ready;
        }
        // Linux/macOS: use poll() with timeout so we can re-check
        // self.running during the accept loop. A bare return true
        // would make the blocking accept() un-interruptible on close.
        const fd = self.handle;
        var pfd = [_]posix.pollfd{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const timeout: i32 = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i32))));
        const rc = posix.poll(&pfd, timeout) catch return false;
        const ready = rc > 0;
        return ready;
    }

    /// Returns the local address the socket is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posixGetSockName(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns the connected peer address.
    pub fn getPeerAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posixGetPeerName(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns a reader interface for the socket.
    pub fn reader(self: *Self) any_io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = struct {
                fn read(ctx: *anyopaque, buffer: []u8) anyerror!usize {
                    const s: *Socket = @ptrCast(@alignCast(ctx));
                    return s.recv(buffer);
                }
            }.read,
        };
    }

    /// Returns a writer interface for the socket.
    pub fn writer(self: *Self) any_io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = struct {
                fn write(ctx: *anyopaque, data: []const u8) anyerror!usize {
                    const s: *Socket = @ptrCast(@alignCast(ctx));
                    return s.send(data);
                }
            }.write,
        };
    }
};

pub fn connectHappyEyeballs(allocator: Allocator, hostname: []const u8, port: u16, timeout_ms: u64) !Socket {
    var list = try net.getAddressList(allocator, hostname, port);
    defer list.deinit();

    std.mem.sort(net.Address, list.addrs, {}, struct {
        fn lessThan(_: void, a: net.Address, b: net.Address) bool {
            return switch (a.any.family) {
                posix.AF.INET6 => true,
                else => switch (b.any.family) {
                    posix.AF.INET6 => false,
                    else => true,
                },
            };
        }
    }.lessThan);

    const per_attempt: u64 = @min(timeout_ms / 2, 250);

    for (list.addrs) |addr| {
        var sock = Socket.createForAddress(addr) catch continue;
        sock.connectWithTimeout(addr, per_attempt) catch {
            sock.close();
            continue;
        };
        return sock;
    }

    return error.ConnectFailed;
}

/// TCP listener for accepting incoming connections.
pub const TcpListener = struct {
    socket: Socket,

    const Self = @This();

    /// Creates and binds a TCP listener to the address.
    pub fn init(addr: net.Address) !Self {
        const result = initWithBacklog(addr, 128) catch |err| {
            return err;
        };
        return result;
    }

    /// Resolves and creates a TCP listener for `host:port`.
    pub fn initHost(host: []const u8, port: u16) !Self {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        return Self.init(addr);
    }

    /// Creates and binds a TCP listener to the address with explicit backlog.
    pub fn initWithBacklog(addr: net.Address, backlog: u31) !Self {
        var socket = try Socket.createForAddress(addr);
        errdefer socket.close();

        // Enable dual-stack for IPv6 sockets by default.
        if (addr.any.family == std.posix.AF.INET6) {
            socket.setDualStack(false) catch {}; // IPV6_V6ONLY=0: accept both IPv4 and IPv6
        }

        try socket.setReuseAddr(true);
        try socket.bind(addr);
        try socket.listen(backlog);

        return .{ .socket = socket };
    }

    /// Resolves and creates a TCP listener for `host:port` with explicit backlog.
    pub fn initHostWithBacklog(host: []const u8, port: u16, backlog: u31) !Self {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        return initWithBacklog(addr, backlog);
    }

    /// Closes the listener.
    pub fn deinit(self: *Self) void {
        self.socket.close();
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !Socket.AcceptResult {
        return self.socket.accept();
    }

    /// Returns the local address the listener is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posixGetSockName(self.socket.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns the port the listener is bound to. Useful for port 0 (ephemeral port) scenarios
    /// where the OS assigns a port at bind time.
    pub fn getLocalPort(self: *Self) !u16 {
        const addr = try self.getLocalAddress();
        return addr.getPort();
    }
};

/// UDP datagram socket abstraction.
///
/// This is a low-level building block used for DNS, QUIC, custom protocols, etc.
/// It intentionally does not hide allocation or buffering.
pub const UdpSocket = struct {
    handle: posix.socket_t,
    connected: bool = false,

    const Self = @This();

    /// Creates a new UDP socket (IPv4 by default).
    pub fn create() !Self {
        return createV4();
    }

    /// Creates a new UDP socket for IPv4.
    pub fn createV4() !Self {
        try init();
        const handle = try posixSocket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new UDP socket for IPv6.
    pub fn createV6() !Self {
        try init();
        const handle = try posixSocket(posix.AF.INET6, posix.SOCK.DGRAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a UDP socket using the address family of the provided address.
    pub fn createForAddress(addr: net.Address) !Self {
        try init();
        const handle = try posixSocket(addr.any.family, posix.SOCK.DGRAM, 0);
        return .{ .handle = handle };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        if (self.isValid()) {
            posixClose(self.handle);
            self.handle = INVALID_SOCKET;
            self.connected = false;
        }
    }

    /// Returns true if the socket handle is valid.
    pub fn isValid(self: *const Self) bool {
        return self.handle != INVALID_SOCKET;
    }

    /// Binds the socket to an address.
    pub fn bind(self: *Self, addr: net.Address) !void {
        try posixBind(self.handle, &addr.any, addr.getOsSockLen());
    }

    /// Resolves and binds to `host:port`.
    pub fn bindHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        try self.bind(addr);
    }

    /// Connects the UDP socket to a default peer address.
    /// After calling this, `send`/`recv` operate on that peer.
    pub fn connect(self: *Self, addr: net.Address) !void {
        try posixConnect(self.handle, &addr.any, addr.getOsSockLen());
        self.connected = true;
    }

    /// Resolves and connects to `host:port`.
    pub fn connectHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        try self.connect(addr);
    }

    /// Parses and connects an endpoint like `host:port`.
    pub fn connectEndpoint(self: *Self, endpoint: []const u8, default_port: u16) !void {
        const parsed = try address.parseHostPort(endpoint, default_port);
        try self.connectHost(parsed.host, parsed.port);
    }

    /// Sends a datagram to the connected peer.
    pub fn send(self: *Self, data: []const u8) !usize {
        return posixSend(self.handle, data, 0);
    }

    /// Compatibility alias for stream-style write APIs.
    pub fn write(self: *Self, data: []const u8) !usize {
        return self.send(data);
    }

    /// Sends a datagram to a specific address.
    pub fn sendTo(self: *Self, addr: net.Address, data: []const u8) !usize {
        return posixSendTo(self.handle, data, 0, &addr.any, addr.getOsSockLen());
    }

    /// Resolves destination host and sends a datagram.
    pub fn sendToHost(self: *Self, host: []const u8, port: u16, data: []const u8) !usize {
        const addr = try address.resolve(std.heap.page_allocator, host, port);
        return self.sendTo(addr, data);
    }

    /// Receives a datagram from the connected peer.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        return posixRecv(self.handle, buffer, 0);
    }

    /// Compatibility alias for stream-style read APIs.
    pub fn read(self: *Self, buffer: []u8) !usize {
        return self.recv(buffer);
    }

    /// Receives a datagram and returns the source address.
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { n: usize, addr: net.Address } {
        var addr: posix.sockaddr = undefined;
        while (true) {
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            if (is_windows) {
                const recv_len: i32 = std.math.cast(i32, buffer.len) orelse return UdpError.RecvFailed;
                var raw_len: i32 = @intCast(addr_len);
                const rc = winsock.recvfrom(toWinsockSocket(self.handle), buffer.ptr, recv_len, 0, &addr, &raw_len);
                if (rc == winsock.SOCKET_ERROR) {
                    switch (winsock.WSAGetLastError()) {
                        winsock.WSAEINTR => continue,
                        winsock.WSAEWOULDBLOCK => return error.WouldBlock,
                        winsock.WSAECONNREFUSED => return error.ConnectionRefused,
                        winsock.WSAECONNRESET => return error.ConnectionResetByPeer,
                        winsock.WSAETIMEDOUT => return error.ConnectionTimedOut,
                        winsock.WSAENOBUFS => return error.SystemResources,
                        winsock.WSAENOTCONN => return error.SocketNotConnected,
                        else => return UdpError.RecvFailed,
                    }
                }

                return .{ .n = @intCast(rc), .addr = net.Address{ .any = addr } };
            }

            const rc = posix.system.recvfrom(self.handle, buffer.ptr, buffer.len, 0, &addr, &addr_len);
            switch (posix.errno(rc)) {
                .SUCCESS => return .{ .n = @intCast(rc), .addr = net.Address{ .any = addr } },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .CONNREFUSED => return error.ConnectionRefused,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                .NOMEM => return error.SystemResources,
                .NOTCONN => return error.SocketNotConnected,
                // Closing the socket from another thread while blocked in recvfrom
                // is a valid shutdown path for the HTTP/3 server loop.
                .BADF, .NOTSOCK, .FAULT, .INVAL => return UdpError.RecvFailed,
                else => return UdpError.RecvFailed,
            }
        }
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }

    /// Enables or disables UDP broadcast.
    pub fn setBroadcast(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the receive buffer size in bytes.
    pub fn setRecvBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&value));
    }

    /// Sets the send timeout in milliseconds.
    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the send buffer size in bytes.
    pub fn setSendBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posixSetSockOpt(self.handle, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&value));
    }

    /// Returns the local address the socket is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posixGetSockName(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns the connected peer address.
    pub fn getPeerAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posixGetPeerName(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }
};

test "Socket create and close" {
    var socket = try Socket.create();
    defer socket.close();
    try std.testing.expect(socket.isValid());
}

test "Socket options" {
    var socket = try Socket.create();
    defer socket.close();

    try socket.setNoDelay(true);
    try socket.setReuseAddr(true);
    try socket.setKeepAlive(true);
}

test "TcpListener getLocalAddress" {
    var listener = try TcpListener.init(try net.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();
    // port should be assigned
    try std.testing.expect(addr.getPort() != 0);
}

test "UdpSocket send/recv localhost" {
    var recv_sock = try UdpSocket.create();
    defer recv_sock.close();

    try recv_sock.setReuseAddr(true);
    try recv_sock.setRecvTimeout(2000);
    try recv_sock.bind(try net.Address.parseIp("127.0.0.1", 0));
    const recv_addr = try recv_sock.getLocalAddress();

    var send_sock = try UdpSocket.create();
    defer send_sock.close();

    const msg = "ping";
    _ = try send_sock.sendTo(recv_addr, msg);

    var buf: [32]u8 = undefined;
    const got = try recv_sock.recvFrom(&buf);
    try std.testing.expectEqualStrings(msg, buf[0..got.n]);
}

test "Socket read/writeAll compatibility aliases" {
    const ThreadCtx = struct {
        listener: *TcpListener,
    };

    const server = struct {
        fn run(ctx: *ThreadCtx) void {
            var accepted = ctx.listener.accept() catch return;
            defer accepted.socket.close();

            var in_buf: [16]u8 = undefined;
            const n = accepted.socket.read(&in_buf) catch return;
            if (std.mem.eql(u8, in_buf[0..n], "ping")) {
                accepted.socket.writeAll("pong") catch return;
            }
        }
    }.run;

    var listener = try TcpListener.init(try net.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();
    var ctx = ThreadCtx{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, server, .{&ctx});
    defer thread.join();

    var client = try Socket.createForAddress(addr);
    defer client.close();

    try client.connect(addr);
    try client.writeAll("ping");

    var out_buf: [16]u8 = undefined;
    const n = try client.read(&out_buf);
    try std.testing.expectEqualStrings("pong", out_buf[0..n]);
}

test "SocketIoReader readVec fills internal buffer for empty input" {
    const ThreadCtx = struct {
        listener: *TcpListener,
    };
    const payload = "hello";

    const server = struct {
        fn run(ctx: *ThreadCtx) void {
            var accepted = ctx.listener.accept() catch return;
            defer accepted.socket.close();

            accepted.socket.writeAll(payload) catch return;
        }
    }.run;

    var listener = try TcpListener.init(try net.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();
    var ctx = ThreadCtx{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, server, .{&ctx});
    defer thread.join();

    var client = try Socket.createForAddress(addr);
    defer client.close();

    try client.connect(addr);

    var scratch: [32]u8 = undefined;
    var io_reader = SocketIoReader.init(&client, scratch[0..]);
    var empty_iov = [_][]u8{};

    const n = try SocketIoReader.readVec(&io_reader.reader, &empty_iov);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(payload.len, io_reader.reader.end);
    try std.testing.expectEqual(@as(usize, 0), io_reader.reader.seek);
}

test "Socket helper API compile checks" {
    const create_v4_ptr: *const fn () anyerror!Socket = Socket.createV4;
    const create_v6_ptr: *const fn () anyerror!Socket = Socket.createV6;
    const connect_host_ptr: *const fn (*Socket, []const u8, u16) anyerror!void = Socket.connectHost;
    const connect_endpoint_ptr: *const fn (*Socket, []const u8, u16) anyerror!void = Socket.connectEndpoint;
    const bind_host_ptr: *const fn (*Socket, []const u8, u16) anyerror!void = Socket.bindHost;
    const shutdown_ptr: *const fn (*Socket, ShutdownMode) anyerror!void = Socket.shutdown;
    const shutdown_read_ptr: *const fn (*Socket) anyerror!void = Socket.shutdownRead;
    const shutdown_write_ptr: *const fn (*Socket) anyerror!void = Socket.shutdownWrite;
    const shutdown_both_ptr: *const fn (*Socket) anyerror!void = Socket.shutdownBoth;
    const local_addr_ptr: *const fn (*Socket) anyerror!net.Address = Socket.getLocalAddress;
    const peer_addr_ptr: *const fn (*Socket) anyerror!net.Address = Socket.getPeerAddress;
    const recv_buf_ptr: *const fn (*Socket, u32) anyerror!void = Socket.setRecvBufferSize;
    const send_buf_ptr: *const fn (*Socket, u32) anyerror!void = Socket.setSendBufferSize;

    _ = create_v4_ptr;
    _ = create_v6_ptr;
    _ = connect_host_ptr;
    _ = connect_endpoint_ptr;
    _ = bind_host_ptr;
    _ = shutdown_ptr;
    _ = shutdown_read_ptr;
    _ = shutdown_write_ptr;
    _ = shutdown_both_ptr;
    _ = local_addr_ptr;
    _ = peer_addr_ptr;
    _ = recv_buf_ptr;
    _ = send_buf_ptr;
}

test "TcpListener host helper compile checks" {
    const init_host_ptr: *const fn ([]const u8, u16) anyerror!TcpListener = TcpListener.initHost;
    const init_host_backlog_ptr: *const fn ([]const u8, u16, u31) anyerror!TcpListener = TcpListener.initHostWithBacklog;

    _ = init_host_ptr;
    _ = init_host_backlog_ptr;
}

test "UdpSocket helper API compile checks" {
    const create_for_addr_ptr: *const fn (net.Address) anyerror!UdpSocket = UdpSocket.createForAddress;
    const bind_host_ptr: *const fn (*UdpSocket, []const u8, u16) anyerror!void = UdpSocket.bindHost;
    const connect_host_ptr: *const fn (*UdpSocket, []const u8, u16) anyerror!void = UdpSocket.connectHost;
    const connect_endpoint_ptr: *const fn (*UdpSocket, []const u8, u16) anyerror!void = UdpSocket.connectEndpoint;
    const write_ptr: *const fn (*UdpSocket, []const u8) anyerror!usize = UdpSocket.write;
    const read_ptr: *const fn (*UdpSocket, []u8) anyerror!usize = UdpSocket.read;
    const send_to_host_ptr: *const fn (*UdpSocket, []const u8, u16, []const u8) anyerror!usize = UdpSocket.sendToHost;
    const peer_addr_ptr: *const fn (*UdpSocket) anyerror!net.Address = UdpSocket.getPeerAddress;
    const broadcast_ptr: *const fn (*UdpSocket, bool) anyerror!void = UdpSocket.setBroadcast;
    const recv_buf_ptr: *const fn (*UdpSocket, usize) anyerror!void = UdpSocket.setRecvBufferSize;
    const send_buf_ptr: *const fn (*UdpSocket, usize) anyerror!void = UdpSocket.setSendBufferSize;

    _ = create_for_addr_ptr;
    _ = bind_host_ptr;
    _ = connect_host_ptr;
    _ = connect_endpoint_ptr;
    _ = write_ptr;
    _ = read_ptr;
    _ = send_to_host_ptr;
    _ = peer_addr_ptr;
    _ = broadcast_ptr;
    _ = recv_buf_ptr;
    _ = send_buf_ptr;
}
