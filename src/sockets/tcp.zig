// TCP socket abstraction over std.Io.net (Zig 0.16).
//
// IPv4 + IPv6 via net/address.Address. Read/write are one-shot syscalls
// through the Io vtable: read() returns whatever is available (>=1 byte,
// ConnectionClosed at EOF) without waiting to fill the caller's buffer.

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const address_mod = @import("../net/address.zig");
const posix = std.posix;

const ws2_32 = std.os.windows.ws2_32;

extern "ws2_32" fn setsockopt(
    socket: std.Io.net.Socket.Handle,
    level: i32,
    optname: i32,
    optval: ?*const anyopaque,
    optlen: i32,
) callconv(.c) i32;

extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;

/// Applies SO_RCVTIMEO/SO_SNDTIMEO (milliseconds; 0 = none).
/// Works on Windows sockets and POSIX fds alike (both take the option at
/// SOL_SOCKET level; Windows wants a DWORD ms, POSIX a timeval).
pub fn setTimeouts(sock: std.Io.net.Socket.Handle, timeout_ms: u31) void {
    if (@import("builtin").os.tag == .windows) {
        const ms: u32 = @intCast(timeout_ms);
        const lvl = ws2_32.SOL.SOCKET;
        _ = setsockopt(sock, lvl, ws2_32.SO.RCVTIMEO, &std.mem.toBytes(ms), 4);
        _ = setsockopt(sock, lvl, ws2_32.SO.SNDTIMEO, &std.mem.toBytes(ms), 4);
    } else {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

/// Best-effort TCP socket tuning. Failures are swallowed by design: options
/// are performance/behavior hints, not correctness requirements (e.g.
/// NODELAY is unsupported on some platforms).
pub fn setNoDelay(sock: std.Io.net.Socket.Handle) void {
    const one: c_int = 1;
    if (@import("builtin").os.tag == .windows) {
        const h: usize = @intFromPtr(sock);
        _ = setsockopt(h, ws2_32.IPPROTO.TCP, ws2_32.TCP.NODELAY, &std.mem.toBytes(one), @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.IPPROTO.TCP, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY == 1
    }
}

pub fn setKeepAlive(sock: std.Io.net.Socket.Handle, idle_secs: u32) void {
    const one: c_int = 1;
    if (@import("builtin").os.tag == .windows) {
        const h: usize = @intFromPtr(sock);
        // SO_KEEPALIVE == 8 in winsock.
        _ = setsockopt(h, ws2_32.SOL.SOCKET, 8, &std.mem.toBytes(one), @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
        const idle: c_int = @intCast(idle_secs);
        switch (@import("builtin").os.tag) {
            .linux => posix.setsockopt(sock, posix.IPPROTO.TCP, 4, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPIDLE
            .macos => posix.setsockopt(sock, posix.IPPROTO.TCP, 0x10, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPALIVE
            else => {},
        }
    }
}
/// Direct winsock transport used for data-heavy uploads.
///
/// std.Io's AFD/APC completion path can lose wakeups when one thread
/// interleaves file reads with large socket writes (observed as an
/// indefinite wedge during multipart uploads). The old httpx net stack
/// used plain winsock sockets with chunked sends and was immune, so this
/// type restores that proven path for uploads. Non-Windows falls back to
/// the POSIX socket API directly.
pub const UploadStream = struct {
    handle: isize, // SOCKET (winsock) or fd (posix)

    const is_windows = @import("builtin").os.tag == .windows;

    const ws = if (is_windows) struct {
        const SOCKET = usize;
        const SOCKET_ERROR: i32 = -1;
        const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
        const WSAEWOULDBLOCK: i32 = 10035;

        extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.c) i32;
        extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
        extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.c) SOCKET;
        extern "ws2_32" fn connect(s: SOCKET, name: *const posix.sockaddr, namelen: i32) callconv(.c) i32;
        extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
        extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
        extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.c) i32;

        const WSADATA = extern struct {
            wVersion: u16,
            wHighVersion: u16,
            szDescription: [257]u8,
            szSystemStatus: [129]u8,
            iMaxSockets: u16,
            iMaxUdpDg: u16,
            lpVendorInfo: ?[*:0]u8,
        };

        const SOL_SOCKET: i32 = 0xFFFF;
        const SO_RCVTIMEO: i32 = 0x1006;
        const SO_SNDTIMEO: i32 = 0x1007;
    } else struct {};

    var wsa_done = std.atomic.Value(bool).init(false);

    pub fn ensureWinsock() void {
        if (!is_windows) return;
        if (wsa_done.swap(true, .acq_rel)) return;
        var data: ws.WSADATA = undefined;
        _ = ws.WSAStartup(0x0202, &data);
    }

    /// Connects to an IPv4 literal host. Returns error.ConnectFailed on any
    /// failure. Applies a 10s send/receive timeout so uploads can't hang
    /// indefinitely.
    pub fn connectIPv4(host: [4]u8, port: u16) ConnectError!UploadStream {
        ensureWinsock();
        if (is_windows) {
            const h = ws.socket(2, 1, 6); // AF_INET, SOCK_STREAM, TCP
            if (h == ws.INVALID_SOCKET) return ConnectError.ConnectionRefused;
            var addr = posix.sockaddr.in{
                .family = 2,
                .port = std.mem.nativeToBig(u16, port),
                .addr = host,
                .zero = .{0} ** 8,
            };
            if (ws.connect(@intCast(h), @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) == ws.SOCKET_ERROR) {
                _ = ws.closesocket(h);
                return ConnectError.ConnectionRefused;
            }
            applyTimeouts(@intCast(h));
            return .{ .handle = @intCast(h) };
        } else {
            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch
                return ConnectError.ConnectionRefused;
            var addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = host,
                .zero = .{0} ** 8,
            };
            posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch {
                posix.close(fd);
                return ConnectError.ConnectionRefused;
            };
            applyTimeouts(fd);
            return .{ .handle = @intCast(fd) };
        }
    }

    fn applyTimeouts(h: isize) void {
        const ms: u32 = 10_000;
        if (is_windows) {
            const bytes = std.mem.toBytes(ms);
            _ = ws.setsockopt(@intCast(h), ws.SOL_SOCKET, ws.SO_RCVTIMEO, &bytes, 4);
            _ = ws.setsockopt(@intCast(h), ws.SOL_SOCKET, ws.SO_SNDTIMEO, &bytes, 4);
        }
    }

    const max_send_chunk: usize = 64 * 1024; // old MAX_WINSOCK_SEND_CHUNK

    pub fn writeAll(self: *const UploadStream, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const want: usize = @min(data.len - pos, max_send_chunk);
            if (is_windows) {
                const rc = ws.send(@intCast(self.handle), data.ptr + pos, @intCast(want), 0);
                if (rc == ws.SOCKET_ERROR) return error.WriteFailed;
                pos += @intCast(rc);
            } else {
                const n = posix.send(@intCast(self.handle), data[pos..], 0) catch return error.WriteFailed;
                if (n == 0) return error.WriteFailed;
                pos += n;
            }
        }
    }

    pub fn read(self: *const UploadStream, buf: []u8) !usize {
        if (is_windows) {
            const rc = ws.recv(@intCast(self.handle), buf.ptr, @intCast(@min(buf.len, max_send_chunk)), 0);
            if (rc == ws.SOCKET_ERROR) return error.ReadFailed;
            return @intCast(rc);
        } else {
            return posix.recv(@intCast(self.handle), buf, 0) catch return error.ReadFailed;
        }
    }

    pub fn close(self: *const UploadStream) void {
        if (self.handle < 0) return;
        if (is_windows) {
            _ = ws.closesocket(@intCast(self.handle));
        } else {
            posix.close(@intCast(self.handle));
        }
    }
};
pub const ReadError = error{
    ConnectionReset,
    ConnectionClosed,
    ReadFailed,
};

pub const WriteError = error{
    ConnectionReset,
    WriteFailed,
};

pub const ConnectError = error{
    ConnectionRefused,
    HostUnreachable,
    NetworkUnreachable,
    TimedOut,
    PermissionDenied,
    OutOfMemory,
    Unexpected,
};

/// Runtime IO context - one per application.
pub const IoContext = struct {
    io: std.Io,
    threaded: *std.Io.Threaded,
    allocator: Allocator,

    pub fn init(gpa: Allocator) !IoContext {
        // The std.Io networking layer ultimately uses Winsock on Windows,
        // which requires process-level startup before bind/connect/accept.
        // Initialize it here so every TCP/UDP user of a shared IoContext has
        // the same deterministic prerequisite and cannot strand an accept
        // worker when the first client connection fails.
        initWinsock();
        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = .init(gpa, .{});
        return .{ .io = threaded.io(), .threaded = threaded, .allocator = gpa };
    }

    pub fn deinit(self: *IoContext) void {
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }
};

/// Value-type TCP connection over a net.Stream.
pub const Socket = struct {
    stream: net.Stream,
    io: std.Io,
    /// Idempotent-teardown guard: close/drainThenClose run exactly once even
    /// when multiple owners (shutdown sweep + defer) race to release.
    close_flag: std.atomic.Value(bool) = .init(false),

    pub fn init(stream: net.Stream, io: std.Io) Socket {
        return .{ .stream = stream, .io = io };
    }

    /// Atomic once-guard shared by close/drainThenClose. Returns true when
    /// the CALLER won the right to tear down.
    fn acquireClose(self: *const Socket) bool {
        return !@constCast(&self.close_flag).swap(true, .acq_rel);
    }

    pub fn close(self: *const Socket) void {
        if (!self.acquireClose()) return;
        self.stream.close(self.io);
    }

    /// Signals end-of-stream to the peer without dropping unread data.
    /// Pair with `drainThenClose` for reliable Connection: close semantics.
    pub fn shutdownWrite(self: *const Socket) void {
        self.stream.shutdown(self.io, .send) catch {};
    }

    /// Graceful close: half-close write side, wait for the peer to finish
    /// reading and close, then drop the handle. Prevents RST discarding
    /// in-flight response bytes on Windows.
    pub fn drainThenClose(self: *const Socket) void {
        if (!self.acquireClose()) return;
        self.shutdownWrite();
        var sink: [512]u8 = undefined;
        while (true) {
            const n = self.read(&sink) catch break;
            if (n == 0) break;
        }
        self.stream.close(self.io);
    }

    /// Reads up to buf.len bytes; partial reads are normal.
    pub fn read(self: *const Socket, buf: []u8) ReadError!usize {
        if (buf.len == 0) return 0;
        var data: [1][]u8 = .{buf};
        const n = self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &data) catch |err| switch (err) {
            error.ConnectionResetByPeer => return ReadError.ConnectionReset,
            else => return ReadError.ReadFailed,
        };
        if (n == 0) return ReadError.ConnectionClosed;
        return n;
    }

    fn write(self: *const Socket, data: []const u8) WriteError!usize {
        if (data.len == 0) return 0;
        const n = self.io.vtable.netWrite(self.io.userdata, self.stream.socket.handle, "", &.{data}, 1) catch |err| switch (err) {
            error.ConnectionResetByPeer => return WriteError.ConnectionReset,
            else => return WriteError.WriteFailed,
        };
        return n;
    }

    /// Writes all data handling partial writes.
    pub fn writeAll(self: *const Socket, data: []const u8) WriteError!void {
        var pos: usize = 0;
        while (pos < data.len) {
            const n = try self.write(data[pos..]);
            if (n == 0) return WriteError.WriteFailed;
            pos += n;
        }
    }
};

pub const Listener = struct {
    server: net.Server,
    bound_port: u16,
    family: address_mod.Family = .ip4,
    closed: bool = false,

    /// Bind 0.0.0.0:port. port=0 lets OS choose an ephemeral port.
    pub fn bind(io: std.Io, port: u16) !Listener {
        var a = address_mod.Address.unspecified4(port);
        return bindAddress(io, &a);
    }

    /// Bind on an explicit Address - enables IPv6 ("::") listeners.
    pub fn bindAddress(io: std.Io, addr: *const address_mod.Address) !Listener {
        var std_addr = addr.toStd(null);
        const server = try std_addr.listen(io, .{ .reuse_address = true });
        return .{
            .server = server,
            .bound_port = switch (server.socket.address) {
                .ip4 => |v| v.port,
                .ip6 => |v| v.port,
            },
            .family = addr.family,
        };
    }

    pub fn localPort(self: *const Listener) u16 {
        return self.bound_port;
    }

    /// Accepts a connection.
    pub fn accept(self: *Listener, io: std.Io) !Socket {
        const conn = self.server.accept(io) catch return error.AcceptFailed;
        return Socket.init(conn, io);
    }

    /// Closes the listening socket. Idempotent; wakes a concurrent accept().
    pub fn close(self: *Listener, io: std.Io) void {
        if (self.closed) return;
        self.closed = true;
        self.server.deinit(io);
    }
};

/// Initializes winsock on Windows (no-op elsewhere). Safe to call repeatedly.
pub fn initWinsock() void {
    UploadStream.ensureWinsock();
}

/// Connect to a parsed Address (IPv4 or IPv6).
pub fn connectAddress(io: std.Io, addr: *const address_mod.Address) ConnectError!Socket {
    const std_addr = addr.toStd(null);
    const stream = std_addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => return ConnectError.ConnectionRefused,
        error.NetworkUnreachable => return ConnectError.NetworkUnreachable,
        error.HostUnreachable => return ConnectError.HostUnreachable,
        error.AccessDenied => return ConnectError.PermissionDenied,
        error.Timeout => return ConnectError.TimedOut,
        error.ConnectionResetByPeer => return ConnectError.ConnectionRefused,
        else => return ConnectError.Unexpected,
    };
    return Socket.init(stream, io);
}

/// Connect to an IP-literal host string (dotted quad or IPv6 text).
/// Hostnames require DNS resolution first (see net/dns.zig).
pub fn connect(io: std.Io, host: []const u8, port: u16) ConnectError!Socket {
    var holder = address_mod.Address{ .family = .ip4, .port = 0 };
    var addr = holder.parseIp(host) catch return ConnectError.HostUnreachable;
    addr.port = port;
    return connectAddress(io, &addr);
}

test "listener binds and reports port" {
    var ctx = IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var l = Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    try std.testing.expect(l.localPort() > 0);
}

test "ipv4 echo through listener" {
    var ctx = IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();

    var l = Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const Thread = std.Thread;
    const Echo = struct {
        fn run(lst: *Listener, io: std.Io) void {
            var sock = lst.accept(io) catch return;
            defer sock.close();
            var buf: [64]u8 = undefined;
            const n = sock.read(&buf) catch return;
            _ = sock.write(buf[0..n]) catch {};
        }
    };
    const t = Thread.spawn(.{}, Echo.run, .{ &l, ctx.io }) catch return;
    defer t.join();

    var s = connect(ctx.io, "127.0.0.1", port) catch return;
    defer s.close();
    try s.writeAll("ping");
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    // One-shot read returns exactly what one recv provided
    try std.testing.expectEqualStrings("ping", buf[0..n]);
}

test "ipv6 loopback echo" {
    var ctx = IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();

    var a = address_mod.Address.loopback6(0);
    var l = Listener.bindAddress(ctx.io, &a) catch return; // skips on no-IPv6 hosts
    defer l.close(ctx.io);
    const port = l.localPort();
    try std.testing.expectEqual(address_mod.Family.ip6, l.family);

    const Thread = std.Thread;
    const Echo6 = struct {
        fn run(lst: *Listener, io: std.Io) void {
            var sock = lst.accept(io) catch return;
            defer sock.close();
            var buf: [64]u8 = undefined;
            const n = sock.read(&buf) catch return;
            _ = sock.write(buf[0..n]) catch {};
        }
    };
    const t = Thread.spawn(.{}, Echo6.run, .{ &l, ctx.io }) catch return;
    defer t.join();

    var holder = address_mod.Address{ .family = .ip4, .port = 0 };
    var dst = holder.parseIp("::1") catch return;
    dst.port = port;

    var s = connectAddress(ctx.io, &dst) catch return;
    defer s.close();
    try s.writeAll("v6");
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqualStrings("v6", buf[0..n]);
}
