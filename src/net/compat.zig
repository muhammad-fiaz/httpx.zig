//! Network compatibility layer for Zig 0.16
//!
//! Provides the `net.Address` type and raw socket operations that were removed
//! from `std.posix` in Zig 0.16. On Windows, these delegate to ws2_32 via the
//! C ABI; on POSIX platforms they use `posix.system` (raw syscalls).

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Network address, wrapping a platform sockaddr.
pub const Address = struct {
    any: posix.sockaddr,

    pub fn initIp4(addr: [4]u8, port: u16) Address {
        var sa: posix.sockaddr = std.mem.zeroes(posix.sockaddr);
        const sa_in: *align(1) SockaddrIn = @ptrCast(&sa);
        sa_in.family = AF_INET;
        sa_in.port = @byteSwap(port);
        sa_in.addr = @as(*align(1) const u32, @ptrCast(&addr)).*;
        return .{ .any = sa };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        var storage: [128]u8 = std.mem.zeroes([128]u8);
        const sa_in6: *align(1) SockaddrIn6 = @ptrCast(&storage);
        sa_in6.family = AF_INET6;
        sa_in6.port = @byteSwap(port);
        sa_in6.flowinfo = flowinfo;
        sa_in6.addr = addr;
        sa_in6.scope_id = scope_id;
        return .{ .any = @as(*align(1) const posix.sockaddr, @ptrCast(&storage)).* };
    }

    pub fn parseIp(ip: []const u8, port: u16) !Address {
        // Try IPv4 first
        if (parseIp4Octets(ip)) |octets| {
            return initIp4(octets, port);
        }
        // TODO: IPv6 parsing
        return error.InvalidAddress;
    }

    pub fn getPort(self: Address) u16 {
        // Port is at the same offset for both IPv4 and IPv6.
        const sa_in: *align(1) const SockaddrIn = @ptrCast(&self.any);
        return @byteSwap(sa_in.port);
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        const sa_in: *align(1) const SockaddrIn = @ptrCast(&self.any);
        if (sa_in.family == AF_INET) return @sizeOf(SockaddrIn);
        if (sa_in.family == AF_INET6) return @sizeOf(SockaddrIn6);
        return @sizeOf(posix.sockaddr);
    }

    fn parseIp4Octets(str: []const u8) ?[4]u8 {
        var result: [4]u8 = undefined;
        var octet_idx: usize = 0;
        var current: u16 = 0;
        var digits: usize = 0;
        for (str) |c| {
            if (c == '.') {
                if (digits == 0 or octet_idx >= 3) return null;
                result[octet_idx] = @intCast(current);
                octet_idx += 1;
                current = 0;
                digits = 0;
            } else if (c >= '0' and c <= '9') {
                current = current * 10 + (c - '0');
                if (current > 255) return null;
                digits += 1;
            } else return null;
        }
        if (digits == 0 or octet_idx != 3) return null;
        result[3] = @intCast(current);
        return result;
    }

    const AF_INET: u16 = if (is_windows) 2 else posix.AF.INET;
    const AF_INET6: u16 = if (is_windows) 23 else posix.AF.INET6;

    const SockaddrIn = extern struct {
        family: u16,
        port: u16,
        addr: u32,
        zero: [8]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    const SockaddrIn6 = extern struct {
        family: u16,
        port: u16,
        flowinfo: u32,
        addr: [16]u8,
        scope_id: u32,
    };
};

// --- Raw socket operations ---
// On Windows, call ws2_32 via C ABI. On POSIX, use posix.system raw syscalls.

const SOCK_STREAM: u32 = if (is_windows) 1 else @intFromEnum(posix.SOCK.STREAM);
const SOCK_DGRAM: u32 = if (is_windows) 2 else @intFromEnum(posix.SOCK.DGRAM);

pub fn socketCreate(family: u32, socktype: u32, protocol: u32) !posix.socket_t {
    if (is_windows) {
        const handle = ws2_socket(@intCast(family), @intCast(socktype), @intCast(protocol));
        if (handle == INVALID_SOCKET_WIN) return error.SocketCreateFailed;
        return handle;
    } else {
        const rc = posix.system.socket(family, socktype, protocol);
        const e = posix.errno(rc);
        if (e != .SUCCESS) return error.SocketCreateFailed;
        return @intCast(rc);
    }
}

pub fn socketConnect(fd: posix.socket_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !void {
    if (is_windows) {
        const rc = ws2_connect(fd, addr, @intCast(addrlen));
        if (rc != 0) return error.ConnectionRefused;
    } else {
        while (true) {
            const rc = posix.system.connect(fd, @ptrCast(addr), addrlen);
            const e = posix.errno(rc);
            switch (e) {
                .SUCCESS => return,
                .INTR => continue,
                .INPROGRESS => return,
                else => return error.ConnectionRefused,
            }
        }
    }
}

pub fn socketBind(fd: posix.socket_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !void {
    if (is_windows) {
        const rc = ws2_bind(fd, addr, @intCast(addrlen));
        if (rc != 0) return error.AddressInUse;
    } else {
        const rc = posix.system.bind(fd, @ptrCast(addr), addrlen);
        const e = posix.errno(rc);
        if (e != .SUCCESS) return error.AddressInUse;
    }
}

pub fn socketListen(fd: posix.socket_t, backlog: u31) !void {
    if (is_windows) {
        const rc = ws2_listen(fd, @intCast(backlog));
        if (rc != 0) return error.AddressInUse;
    } else {
        const rc = posix.system.listen(fd, backlog);
        const e = posix.errno(rc);
        if (e != .SUCCESS) return error.AddressInUse;
    }
}

pub fn socketAccept(fd: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) !posix.socket_t {
    if (is_windows) {
        const handle = ws2_accept(fd, addr, @ptrCast(addrlen));
        if (handle == INVALID_SOCKET_WIN) return error.ConnectionAborted;
        return handle;
    } else {
        while (true) {
            const rc = posix.system.accept(fd, @ptrCast(addr), @ptrCast(addrlen));
            const e = posix.errno(rc);
            switch (e) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => return error.ConnectionAborted,
            }
        }
    }
}

pub fn socketSend(fd: posix.socket_t, data: []const u8, flags: u32) !usize {
    if (is_windows) {
        const rc = ws2_send(fd, @ptrCast(data.ptr), @intCast(data.len), @intCast(flags));
        if (rc < 0) return error.BrokenPipe;
        return @intCast(rc);
    } else {
        while (true) {
            const rc = posix.system.sendto(fd, data.ptr, data.len, flags, null, 0);
            const e = posix.errno(rc);
            switch (e) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.BrokenPipe,
            }
        }
    }
}

pub fn socketRecv(fd: posix.socket_t, buffer: []u8, flags: u32) !usize {
    if (is_windows) {
        const rc = ws2_recv(fd, @ptrCast(buffer.ptr), @intCast(buffer.len), @intCast(flags));
        if (rc < 0) return error.ConnectionResetByPeer;
        return @intCast(rc);
    } else {
        while (true) {
            const rc = posix.system.recvfrom(fd, buffer.ptr, buffer.len, flags, null, null);
            const e = posix.errno(rc);
            switch (e) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.ConnectionResetByPeer,
            }
        }
    }
}

pub fn socketSendTo(fd: posix.socket_t, data: []const u8, flags: u32, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !usize {
    if (is_windows) {
        const rc = ws2_sendto(fd, @ptrCast(data.ptr), @intCast(data.len), @intCast(flags), addr, @intCast(addrlen));
        if (rc < 0) return error.BrokenPipe;
        return @intCast(rc);
    } else {
        while (true) {
            const rc = posix.system.sendto(fd, data.ptr, data.len, flags, @ptrCast(addr), addrlen);
            const e = posix.errno(rc);
            switch (e) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => return error.BrokenPipe,
            }
        }
    }
}

pub const ShutdownHow = enum {
    recv,
    send,
    both,
};

pub fn socketShutdown(fd: posix.socket_t, how: ShutdownHow) !void {
    if (is_windows) {
        const val: c_int = switch (how) {
            .recv => 0,
            .send => 1,
            .both => 2,
        };
        _ = ws2_shutdown(fd, val);
    } else {
        const rc = posix.system.shutdown(fd, switch (how) {
            .recv => 0,
            .send => 1,
            .both => 2,
        });
        const e = posix.errno(rc);
        if (e != .SUCCESS and e != .NOTCONN) return error.SocketNotConnected;
    }
}

pub fn socketClose(fd: posix.socket_t) void {
    if (is_windows) {
        _ = ws2_closesocket(fd);
    } else {
        _ = posix.system.close(fd);
    }
}

pub fn socketGetsockname(fd: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) !void {
    if (is_windows) {
        var wlen: c_int = @intCast(addrlen.*);
        const rc = ws2_getsockname(fd, addr, &wlen);
        if (rc != 0) return error.SocketNotConnected;
        addrlen.* = @intCast(wlen);
    } else {
        const rc = posix.system.getsockname(fd, @ptrCast(addr), @ptrCast(addrlen));
        const e = posix.errno(rc);
        if (e != .SUCCESS) return error.SocketNotConnected;
    }
}

pub fn socketGetpeername(fd: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) !void {
    if (is_windows) {
        var wlen: c_int = @intCast(addrlen.*);
        const rc = ws2_getpeername(fd, addr, &wlen);
        if (rc != 0) return error.SocketNotConnected;
        addrlen.* = @intCast(wlen);
    } else {
        const rc = posix.system.getpeername(fd, @ptrCast(addr), @ptrCast(addrlen));
        const e = posix.errno(rc);
        if (e != .SUCCESS) return error.SocketNotConnected;
    }
}

// Windows ws2_32 extern declarations
const INVALID_SOCKET_WIN: posix.socket_t = if (is_windows) @ptrFromInt(~@as(usize, 0)) else undefined;

extern "ws2_32" fn socket(af: c_int, @"type": c_int, protocol: c_int) callconv(.c) posix.socket_t;
extern "ws2_32" fn connect(s: posix.socket_t, name: *const posix.sockaddr, namelen: c_int) callconv(.c) c_int;
extern "ws2_32" fn bind(s: posix.socket_t, name: *const posix.sockaddr, namelen: c_int) callconv(.c) c_int;
extern "ws2_32" fn listen(s: posix.socket_t, backlog: c_int) callconv(.c) c_int;
extern "ws2_32" fn accept(s: posix.socket_t, addr: *posix.sockaddr, addrlen: *c_int) callconv(.c) posix.socket_t;
extern "ws2_32" fn send(s: posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int;
extern "ws2_32" fn recv(s: posix.socket_t, buf: [*]u8, len: c_int, flags: c_int) callconv(.c) c_int;
extern "ws2_32" fn sendto(s: posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int, to: *const posix.sockaddr, tolen: c_int) callconv(.c) c_int;
extern "ws2_32" fn recvfrom(s: posix.socket_t, buf: [*]u8, len: c_int, flags: c_int, from: *posix.sockaddr, fromlen: *c_int) callconv(.c) c_int;
extern "ws2_32" fn shutdown(s: posix.socket_t, how: c_int) callconv(.c) c_int;
extern "ws2_32" fn closesocket(s: posix.socket_t) callconv(.c) c_int;
extern "ws2_32" fn setsockopt(s: posix.socket_t, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.c) c_int;
extern "ws2_32" fn getsockname(s: posix.socket_t, name: *posix.sockaddr, namelen: *c_int) callconv(.c) c_int;
extern "ws2_32" fn getpeername(s: posix.socket_t, name: *posix.sockaddr, namelen: *c_int) callconv(.c) c_int;

// Wrappers to avoid identifier conflicts with Zig builtins
fn ws2_socket(af: c_int, t: c_int, p: c_int) posix.socket_t {
    return socket(af, t, p);
}
fn ws2_connect(s: posix.socket_t, name: *const posix.sockaddr, len: c_int) c_int {
    return connect(s, name, len);
}
fn ws2_bind(s: posix.socket_t, name: *const posix.sockaddr, len: c_int) c_int {
    return bind(s, name, len);
}
fn ws2_listen(s: posix.socket_t, backlog: c_int) c_int {
    return listen(s, backlog);
}
fn ws2_accept(s: posix.socket_t, addr: *posix.sockaddr, len: *c_int) posix.socket_t {
    return accept(s, addr, len);
}
fn ws2_send(s: posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int) c_int {
    return send(s, buf, len, flags);
}
fn ws2_recv(s: posix.socket_t, buf: [*]u8, len: c_int, flags: c_int) c_int {
    return recv(s, buf, len, flags);
}
fn ws2_sendto(s: posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int, to: *const posix.sockaddr, tolen: c_int) c_int {
    return sendto(s, buf, len, flags, to, tolen);
}
fn ws2_recvfrom(s: posix.socket_t, buf: [*]u8, len: c_int, flags: c_int, from: *posix.sockaddr, fromlen: *c_int) c_int {
    return recvfrom(s, buf, len, flags, from, fromlen);
}
fn ws2_shutdown(s: posix.socket_t, how: c_int) c_int {
    return shutdown(s, how);
}
fn ws2_closesocket(s: posix.socket_t) c_int {
    return closesocket(s);
}
pub fn ws2RecvFrom(s: posix.socket_t, buf: [*]u8, len: c_int, flags: c_int, from: *posix.sockaddr, fromlen: *c_int) c_int {
    return recvfrom(s, buf, len, flags, from, fromlen);
}
fn ws2_getsockname(s: posix.socket_t, name: *posix.sockaddr, namelen: *c_int) c_int {
    return getsockname(s, name, namelen);
}
fn ws2_getpeername(s: posix.socket_t, name: *posix.sockaddr, namelen: *c_int) c_int {
    return getpeername(s, name, namelen);
}
fn ws2_setsockopt(s: posix.socket_t, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) c_int {
    return setsockopt(s, level, optname, optval, optlen);
}

/// Replacement for posix.setsockopt which may have issues on Windows in 0.16.
pub fn setsockoptCompat(fd: posix.socket_t, level: i32, optname: u32, opt: []const u8) !void {
    if (is_windows) {
        const rc = ws2_setsockopt(fd, @intCast(level), @intCast(optname), opt.ptr, @intCast(opt.len));
        if (rc != 0) return error.SocketOptionFailed;
    } else {
        try posix.setsockopt(fd, level, optname, opt);
    }
}
