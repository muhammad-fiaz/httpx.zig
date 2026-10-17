//! TCP socket abstraction over std.Io.net (Zig 0.16).
//!
//! IPv4 + IPv6 via net/address.Address. Read/write are one-shot syscalls
//! through the Io vtable: read() returns whatever is available (>=1 byte,
//! or 0 at EOF) without waiting to fill the caller's buffer.
//!
//! References:
//!   - RFC 9112 Section 8 — Connection Management (TCP lifecycle)
//!   - RFC 9112 Section 9.6 — Persistence (keep-alive, Connection header)
//!   - RFC 1122 — Requirements for Internet Hosts (TCP connection behavior)
//
// Windows-specific design:
// On Windows, std.Io.Threaded.netConnectIpWindows maps the AFD
// STATUS_CONNECTION_REFUSED (NTSTATUS 0xc0000236) to error.Unexpected via
// windows.unexpectedStatus(). In Debug mode, unexpectedStatus() calls
// std.debug.dumpCurrentStackTrace(), which writes to stderr. When the test
// binary is launched with --listen=- (the default for `zig build test`), that
// binary protocol is corrupted by the stderr output, causing mainServer to
// panic and the entire test suite to fail.
//
// Fix: on Windows, connectAddress() bypasses std.Io.net entirely and uses
// ws232.connect() directly. WSAECONNREFUSED (10061) is properly mapped to
// ConnectError.ConnectionRefused with no side effects. Socket.read/write/close
// also use ws232 directly on Windows so the same handle type works end-to-end.
// On other platforms the existing std.Io.net path is unchanged.

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const addressMod = @import("../net/address.zig");
const sync = @import("../common/sync.zig");
const clock = @import("../common/clock.zig");
const posix = std.posix;
const builtin = @import("builtin");

const isWindows = builtin.os.tag == .windows;

// Windows winsock shims
// All declared inside a comptime block so they compile to nothing on non-Windows.

const ws = if (isWindows) struct {
    pub const SOCKET = usize;
    pub const SOCKET_ERROR: i32 = -1;
    pub const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
    pub const AF_INET: i32 = 2;
    pub const AF_INET6: i32 = 23;
    pub const SOCK_STREAM: i32 = 1;
    pub const IPPROTO_TCP: i32 = 6;
    pub const SO_REUSEADDR: i32 = 4;
    pub const SOMAXCONN: i32 = 0x7fffffff;

    pub const sockaddrIn = extern struct {
        family: u16,
        port: u16, // big-endian
        addr: [4]u8,
        zero: [8]u8 = @splat(0),
    };

    pub const sockaddrIn6 = extern struct {
        family: u16,
        port: u16, // big-endian
        flowinfo: u32 = 0,
        addr: [16]u8,
        scopeId: u32 = 0,
    };

    // Winsock error codes
    pub const WSAECONNREFUSED: i32 = 10061;
    pub const WSAEHOSTUNREACH: i32 = 10065;
    pub const WSAEHOSTDOWN: i32 = 10064;
    pub const WSAENETUNREACH: i32 = 10051;
    pub const WSAETIMEDOUT: i32 = 10060;
    pub const WSAEACCES: i32 = 10013;

    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*:0]u8,
    };

    pub extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.c) i32;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
    pub extern "ws2_32" fn socket(af: i32, sockType: i32, protocol: i32) callconv(.c) SOCKET;
    pub extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.c) i32;
    pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) SOCKET;
    pub extern "ws2_32" fn getsockname(s: SOCKET, name: *anyopaque, namelen: *i32) callconv(.c) i32;
    pub extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: ?*const anyopaque, optlen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.c) i32;

    pub const SOL_SOCKET: i32 = 0xFFFF;
    pub const SO_RCVTIMEO: i32 = 0x1006;
    pub const SO_SNDTIMEO: i32 = 0x1007;
    pub const SO_KEEPALIVE: i32 = 8;
    pub const SD_SEND: i32 = 1;
    pub const TCP_NODELAY: i32 = 1;
    pub const IPPROTO_TCP_OPT: i32 = 6;

    var wsaOnce: sync.Once = .{};

    fn doWsaStartup() void {
        var data: WSADATA = undefined;
        _ = WSAStartup(0x0202, &data);
    }

    pub fn startup() void {
        // Once-gated: racing threads block until WSAStartup completes,
        // so nobody observes WSANOTINITIALISED on socket().
        wsaOnce.call(doWsaStartup);
    }

    /// Map winsock last-error to ConnectError without calling unexpectedStatus.
    pub fn mapConnectError() ConnectError {
        return switch (WSAGetLastError()) {
            WSAECONNREFUSED => ConnectError.ConnectionRefused,
            WSAEHOSTUNREACH, WSAEHOSTDOWN => ConnectError.HostUnreachable,
            WSAENETUNREACH => ConnectError.NetworkUnreachable,
            WSAETIMEDOUT => ConnectError.TimedOut,
            WSAEACCES => ConnectError.PermissionDenied,
            else => ConnectError.Unexpected,
        };
    }

    /// Apply 10-second send/receive timeouts (blocking mode).
    pub fn applyTimeouts(s: SOCKET) void {
        const ms: u32 = 10_000;
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &ms, 4);
        _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &ms, 4);
    }
} else struct {};

// Public API for socket tuning

/// Applies SO_RCVTIMEO/SO_SNDTIMEO (milliseconds; 0 = none).
/// Works on Windows sockets and POSIX fds alike (both take the option at
/// SOL_SOCKET level; Windows wants a DWORD ms, POSIX a timeval).
pub fn setTimeouts(sock: net.Socket.Handle, timeoutMs: u31) void {
    setReadSocketTimeout(sock, timeoutMs);
    setWriteSocketTimeout(sock, timeoutMs);
}

fn setReadSocketTimeout(sock: net.Socket.Handle, timeoutMs: u31) void {
    if (isWindows) {
        const ms: u32 = @intCast(timeoutMs);
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_RCVTIMEO, &ms, 4);
    } else {
        const tv = posix.timeval{
            .sec = @intCast(timeoutMs / 1000),
            .usec = @intCast((timeoutMs % 1000) * 1000),
        };
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

fn setWriteSocketTimeout(sock: net.Socket.Handle, timeoutMs: u31) void {
    if (isWindows) {
        const ms: u32 = @intCast(timeoutMs);
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_SNDTIMEO, &ms, 4);
    } else {
        const tv = posix.timeval{
            .sec = @intCast(timeoutMs / 1000),
            .usec = @intCast((timeoutMs % 1000) * 1000),
        };
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

/// Best-effort TCP socket tuning. Failures are swallowed by design: options
/// are performance/behavior hints, not correctness requirements (e.g.
/// NODELAY is unsupported on some platforms).
pub fn setNoDelay(sock: net.Socket.Handle) void {
    const one: c_int = 1;
    if (isWindows) {
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.IPPROTO_TCP_OPT, ws.TCP_NODELAY, &one, @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.IPPROTO.TCP, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY == 1
    }
}

pub fn setKeepAlive(sock: net.Socket.Handle, idleSecs: u32) void {
    const one: c_int = 1;
    if (isWindows) {
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_KEEPALIVE, &one, @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
        const idle: c_int = @intCast(idleSecs);
        switch (builtin.os.tag) {
            .linux => posix.setsockopt(sock, posix.IPPROTO.TCP, 4, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPIDLE
            .macos => posix.setsockopt(sock, posix.IPPROTO.TCP, 0x10, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPALIVE
            else => {},
        }
    }
}

// UploadStream
// Used by the HTTP client for large uploads. On Windows, uses ws232 directly
// to avoid AFD completion-port wedges observed with std.Io for heavy I/O.

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

    var wsaOnce: sync.Once = .{};

    fn doEnsureWsa() void {
        var data: ws.WSADATA = undefined;
        _ = ws.WSAStartup(0x0202, &data);
    }

    pub fn ensureWinsock() void {
        if (!isWindows) return;
        // Once-gated (see ws.startup): racing threads block until WSAStartup
        // completes instead of observing WSANOTINITIALISED on socket().
        wsaOnce.call(doEnsureWsa);
    }

    /// Connects to an IPv4 literal host. Returns error.ConnectFailed on any
    /// failure. Applies a 10s send/receive timeout so uploads can't hang
    /// indefinitely.
    pub fn connectIPv4(host: [4]u8, port: u16) ConnectError!UploadStream {
        ensureWinsock();
        if (isWindows) {
            const h = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) return ConnectError.ConnectionRefused;
            var addr = ws.sockaddrIn{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, port),
                .addr = host,
            };
            if (ws.connect(h, &addr, @sizeOf(ws.sockaddrIn)) == ws.SOCKET_ERROR) {
                // Read the error BEFORE closesocket: successful winsock calls
                // reset the thread's last-error, clobbering the real code.
                const err = ws.mapConnectError();
                _ = ws.closesocket(h);
                return err;
            }
            ws.applyTimeouts(h);
            return .{ .handle = @intCast(h) };
        } else {
            const fd = std.c.socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.STREAM), @intCast(posix.IPPROTO.TCP));
            if (fd < 0) return ConnectError.ConnectionRefused;
            var addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &host, .big)),
                .zero = (@as([8]u8, @splat(0))),
            };
            if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) {
                _ = std.c.close(fd);
                return ConnectError.ConnectionRefused;
            }
            return .{ .handle = @intCast(fd) };
        }
    }

    const maxSendChunk: usize = 64 * 1024; // old MAX_WINSOCK_SEND_CHUNK

    pub fn writeAll(self: *const UploadStream, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const want: usize = @min(data.len - pos, maxSendChunk);
            if (isWindows) {
                const rc = ws.send(@intCast(self.handle), data.ptr + pos, @intCast(want), 0);
                if (rc == ws.SOCKET_ERROR) return error.WriteFailed;
                pos += @intCast(rc);
            } else {
                const n = std.c.send(@intCast(self.handle), data.ptr + pos, want, 0);
                if (n <= 0) return error.WriteFailed;
                pos += @intCast(n);
            }
        }
    }

    pub fn read(self: *const UploadStream, buf: []u8) !usize {
        if (isWindows) {
            const rc = ws.recv(@intCast(self.handle), buf.ptr, @intCast(@min(buf.len, maxSendChunk)), 0);
            if (rc == ws.SOCKET_ERROR) return error.ReadFailed;
            return @intCast(rc);
        } else {
            const n = std.c.recv(@intCast(self.handle), buf.ptr, buf.len, 0);
            if (n < 0) return error.ReadFailed;
            return @intCast(n);
        }
    }

    pub fn close(self: *const UploadStream) void {
        if (self.handle < 0) return;
        if (isWindows) {
            _ = ws.closesocket(@intCast(self.handle));
        } else {
            _ = std.c.close(@intCast(self.handle));
        }
    }
};

// Error sets

pub const ReadError = error{
    ConnectionReset,
    ConnectionClosed,
    ReadFailed,
    Timeout,
};

pub const WriteError = error{
    ConnectionReset,
    WriteFailed,
    Timeout,
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

// IoContext

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

// Socket
//
// On Windows: backed by a raw winsock SOCKET (ws.SOCKET / usize).
// On other platforms: backed by a net.Stream (std.Io.net).
//
// The Windows path avoids std.Io.net entirely because netConnectIpWindows
// (Zig 0.16) calls windows.unexpectedStatus() for STATUS_CONNECTION_REFUSED,
// which dumps a stack trace to stderr and corrupts --listen=- test protocol.

/// Value-type TCP connection.
///
/// Internally a tagged union: `winsock` (raw ws232 SOCKET) or `stream`
/// (std.Io.net.Stream). On Windows, `connectAddress` always produces
/// `winsock` sockets. `Listener.accept` produces `stream` sockets on all
/// platforms (accept never triggers STATUS_CONNECTION_REFUSED so the AFD
/// path is safe there).
///
/// All lifecycle methods (close, drainThenClose) are idempotent via an
/// atomic once-guard so multiple owners cannot double-close.
pub const Socket = struct {
    inner: Inner,
    io: std.Io,
    /// Idempotent-teardown guard.
    closeFlag: std.atomic.Value(bool) = .init(false),
    /// Absolute operation deadlines. A caller resets these at protocol phase
    /// boundaries, so a peer cannot keep a request alive by sending one byte
    /// just before each per-read socket timeout.
    readDeadline: ?std.Io.Clock.Timestamp = null,
    writeDeadline: ?std.Io.Clock.Timestamp = null,
    readDeadlineMs: std.atomic.Value(i64) = .init(0),
    writeDeadlineMs: std.atomic.Value(i64) = .init(0),
    readActive: std.atomic.Value(bool) = .init(false),
    writeActive: std.atomic.Value(bool) = .init(false),
    readInterrupted: std.atomic.Value(bool) = .init(false),
    writeInterrupted: std.atomic.Value(bool) = .init(false),

    const Inner = union(enum) {
        /// Raw ws232 SOCKET — used on Windows for client connections.
        winsock: if (isWindows) ws.SOCKET else void,
        /// std.Io.net stream — used on all platforms for accepted connections
        /// and on non-Windows for client connections too.
        stream: net.Stream,
    };

    // Constructors

    /// Construct from a raw Windows SOCKET (Windows-only client connects).
    pub fn fromWinsock(sock: ws.SOCKET, io: std.Io) Socket {
        return .{ .inner = .{ .winsock = sock }, .io = io };
    }

    /// Construct from a net.Stream (non-Windows client connects + all accepts).
    pub fn init(stream: net.Stream, io: std.Io) Socket {
        return .{ .inner = .{ .stream = stream }, .io = io };
    }

    // Atomic once-guard

    fn acquireClose(self: *const Socket) bool {
        return !@constCast(&self.closeFlag).swap(true, .acq_rel);
    }

    // Close

    pub fn close(self: *const Socket) void {
        if (!self.acquireClose()) return;
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.closesocket(s);
            },
            .stream => |st| st.close(self.io),
        }
    }

    /// Signals end-of-stream to the peer without dropping unread data.
    pub fn shutdownWrite(self: *const Socket) void {
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.shutdown(s, ws.SD_SEND);
            },
            .stream => |st| st.shutdown(self.io, .send) catch {},
        }
    }

    fn shutdownRead(self: *const Socket) void {
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.shutdown(s, 0); // SD_RECEIVE
            },
            .stream => |st| st.shutdown(self.io, .recv) catch {},
        }
    }

    fn shutdownWriteOnly(self: *const Socket) void {
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.shutdown(s, ws.SD_SEND);
            },
            .stream => |st| st.shutdown(self.io, .send) catch {},
        }
    }

    /// Interrupts pending I/O while leaving final handle cleanup to the
    /// socket owner. This avoids racing Windows AFD completion with netClose.
    pub fn interruptIo(self: *const Socket) void {
        self.shutdownRead();
        self.shutdownWriteOnly();
    }

    /// Graceful close: half-close write, drain, then close.
    pub fn drainThenClose(self: *const Socket) void {
        if (!self.acquireClose()) return;
        self.shutdownWrite();
        var sink: [512]u8 = undefined;
        while (true) {
            const n = self.read(&sink) catch break;
            if (n == 0) break;
        }
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.closesocket(s);
            },
            .stream => |st| st.close(self.io),
        }
    }

    /// Probes whether the socket is still open and healthy.
    /// Returns false if closed locally.
    pub fn isAlive(self: *const Socket) bool {
        return !self.closeFlag.load(.monotonic);
    }

    /// Sets an absolute read deadline relative to now; zero disables it.
    pub fn setReadTimeoutMs(self: *Socket, timeoutMs: u32) void {
        self.readDeadline = deadlineAfterMs(self.io, timeoutMs);
        self.readInterrupted.store(false, .release);
        self.readDeadlineMs.store(if (timeoutMs == 0) 0 else clock.monotonicMillis() +| @as(i64, @intCast(timeoutMs)), .release);
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                const ms: u32 = timeoutMs;
                _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_RCVTIMEO, &ms, @sizeOf(u32));
            },
            .stream => |st| setReadSocketTimeout(st.socket.handle, @intCast(@min(timeoutMs, std.math.maxInt(u31)))),
        }
    }

    /// Sets an absolute write deadline relative to now; zero disables it.
    pub fn setWriteTimeoutMs(self: *Socket, timeoutMs: u32) void {
        self.writeDeadline = deadlineAfterMs(self.io, timeoutMs);
        self.writeInterrupted.store(false, .release);
        self.writeDeadlineMs.store(if (timeoutMs == 0) 0 else clock.monotonicMillis() +| @as(i64, @intCast(timeoutMs)), .release);
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                const ms: u32 = timeoutMs;
                _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_SNDTIMEO, &ms, @sizeOf(u32));
            },
            .stream => |st| setWriteSocketTimeout(st.socket.handle, @intCast(@min(timeoutMs, std.math.maxInt(u31)))),
        }
    }

    /// Sets a per-system-call timeout that restarts for each read. Use this
    /// for protocols such as FTP whose legacy timeout is an inactivity limit.
    pub fn setReadInactivityTimeoutMs(self: *Socket, timeoutMs: u32) void {
        self.readDeadline = null;
        self.readDeadlineMs.store(0, .release);
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                const ms: u32 = timeoutMs;
                _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_RCVTIMEO, &ms, @sizeOf(u32));
            },
            .stream => |st| setReadSocketTimeout(st.socket.handle, @intCast(@min(timeoutMs, std.math.maxInt(u31)))),
        }
    }

    /// Sets a per-system-call send timeout that restarts for each write.
    pub fn setWriteInactivityTimeoutMs(self: *Socket, timeoutMs: u32) void {
        self.writeDeadline = null;
        self.writeDeadlineMs.store(0, .release);
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                const ms: u32 = timeoutMs;
                _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_SNDTIMEO, &ms, @sizeOf(u32));
            },
            .stream => |st| setWriteSocketTimeout(st.socket.handle, @intCast(@min(timeoutMs, std.math.maxInt(u31)))),
        }
    }

    fn deadlineAfterMs(io: std.Io, timeoutMs: u32) ?std.Io.Clock.Timestamp {
        if (timeoutMs == 0) return null;
        const duration: std.Io.Clock.Duration = .{
            .raw = .fromMilliseconds(@intCast(timeoutMs)),
            .clock = .awake,
        };
        return .fromNow(io, duration);
    }

    fn remainingTimeoutMs(deadline: ?std.Io.Clock.Timestamp, io: std.Io) ?u31 {
        const until = deadline orelse return null;
        const remaining = until.durationFromNow(io).raw.nanoseconds;
        if (remaining <= 0) return 0;
        const ms = @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, std.math.maxInt(u31)));
    }

    /// Called by the server's deadline monitor. Half-closing the timed-out
    /// direction wakes its pending I/O without racing a full close against
    /// Windows AFD completion processing.
    pub fn closeIfIoDeadlineExpired(self: *const Socket, nowMs: i64) void {
        const readDeadline = @constCast(&self.readDeadlineMs).load(.acquire);
        const readExpired = readDeadline != 0 and nowMs >= readDeadline and self.readActive.load(.acquire);
        const writeDeadline = @constCast(&self.writeDeadlineMs).load(.acquire);
        const writeExpired = writeDeadline != 0 and nowMs >= writeDeadline and self.writeActive.load(.acquire);
        if (readExpired and !@constCast(&self.readInterrupted).swap(true, .acq_rel)) {
            self.shutdownRead();
            self.shutdownWriteOnly();
        }
        if (writeExpired and !@constCast(&self.writeInterrupted).swap(true, .acq_rel)) self.shutdownWriteOnly();
    }

    // I/O

    /// Reads up to buf.len bytes; partial reads are normal.
    pub fn read(self: *const Socket, buf: []u8) ReadError!usize {
        if (buf.len == 0) return 0;
        switch (self.inner) {
            .winsock => |s| {
                if (!isWindows) unreachable;
                if (remainingTimeoutMs(self.readDeadline, self.io)) |ms| {
                    if (ms == 0) return ReadError.Timeout;
                    const timeout: u32 = ms;
                    _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_RCVTIMEO, &timeout, @sizeOf(u32));
                }
                @constCast(&self.readActive).store(true, .release);
                defer @constCast(&self.readActive).store(false, .release);
                const rc = ws.recv(s, buf.ptr, @intCast(@min(buf.len, 65536)), 0);
                if (rc == ws.SOCKET_ERROR) {
                    return switch (ws.WSAGetLastError()) {
                        10054 => ReadError.ConnectionReset, // WSAECONNRESET
                        ws.WSAETIMEDOUT => ReadError.Timeout,
                        0 => ReadError.ConnectionClosed,
                        else => ReadError.ReadFailed,
                    };
                }
                if (rc == 0) return 0; // EOF
                return @intCast(rc);
            },
            .stream => |st| {
                var data: [1][]u8 = .{buf};
                const operation: std.Io.Operation = .{ .net_read = .{
                    .socket_handle = st.socket.handle,
                    .data = &data,
                } };
                if (remainingTimeoutMs(self.readDeadline, self.io)) |ms| {
                    if (ms == 0) return ReadError.Timeout;
                    setReadSocketTimeout(st.socket.handle, @max(1, ms));
                }
                @constCast(&self.readActive).store(true, .release);
                defer @constCast(&self.readActive).store(false, .release);
                const result = self.io.operate(operation) catch return ReadError.ReadFailed;
                const rr = result.net_read catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.Unexpected => return ReadError.ConnectionReset,
                    error.ConnectionTimedOut => return ReadError.Timeout,
                    else => return ReadError.ReadFailed,
                };
                if (rr.data_len == 0) return 0; // EOF
                return rr.data_len;
            },
        }
    }

    fn write(self: *const Socket, data: []const u8) WriteError!usize {
        if (data.len == 0) return 0;
        switch (self.inner) {
            .winsock => |s| {
                if (!isWindows) unreachable;
                if (remainingTimeoutMs(self.writeDeadline, self.io)) |ms| {
                    if (ms == 0) return WriteError.Timeout;
                    const timeout: u32 = ms;
                    _ = ws.setsockopt(s, ws.SOL_SOCKET, ws.SO_SNDTIMEO, &timeout, @sizeOf(u32));
                }
                @constCast(&self.writeActive).store(true, .release);
                defer @constCast(&self.writeActive).store(false, .release);
                const rc = ws.send(s, data.ptr, @intCast(@min(data.len, 65536)), 0);
                if (rc == ws.SOCKET_ERROR) {
                    return switch (ws.WSAGetLastError()) {
                        10054, 10053 => WriteError.ConnectionReset, // WSAECONNRESET, WSAECONNABORTED
                        ws.WSAETIMEDOUT => WriteError.Timeout,
                        else => WriteError.WriteFailed,
                    };
                }
                return @intCast(rc);
            },
            .stream => |st| {
                const chunk = data[0..@min(data.len, 4096)];
                const operation: std.Io.Operation = .{ .net_write = .{
                    .socket_handle = st.socket.handle,
                    .data = &.{chunk},
                } };
                if (remainingTimeoutMs(self.writeDeadline, self.io)) |ms| {
                    if (ms == 0) return WriteError.Timeout;
                    setWriteSocketTimeout(st.socket.handle, @max(1, ms));
                }
                @constCast(&self.writeActive).store(true, .release);
                defer @constCast(&self.writeActive).store(false, .release);
                const result = self.io.operate(operation) catch return WriteError.WriteFailed;
                const n = result.net_write catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.Unexpected => return WriteError.ConnectionReset,
                    error.ConnectionTimedOut => return WriteError.Timeout,
                    else => return WriteError.WriteFailed,
                };
                return n;
            },
        }
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

    /// Returns the underlying std.Io.net socket handle (AFD handle on Windows).
    /// Only valid when the socket was created via `init()` (stream variant).
    /// Used by the TLS layer which requires an AFD-backed socket.
    /// Will be `unreachable` if called on a winsock-variant socket.
    pub fn netSocketHandle(self: *const Socket) net.Socket.Handle {
        return switch (self.inner) {
            .stream => |st| st.socket.handle,
            // winsock sockets have no AFD handle. TLS connections MUST use
            // connectAddressStream() so they always produce the stream variant.
            .winsock => unreachable,
        };
    }
};

// Listener

pub const Listener = struct {
    inner: union(enum) {
        winsock: if (isWindows) ws.SOCKET else void,
        stream: net.Server,
    },
    address: net.IpAddress,
    boundPort: u16,
    family: addressMod.Family = .ip4,
    closed: bool = false,

    /// Bind 0.0.0.0:port. port=0 lets OS choose an ephemeral port.
    pub fn bind(io: std.Io, port: u16) !Listener {
        var a = addressMod.Address.unspecified4(port);
        return bindAddress(io, &a);
    }

    /// Bind on an explicit Address - enables IPv6 ("::")  listeners.
    pub fn bindAddress(io: std.Io, addr: *const addressMod.Address) !Listener {
        if (isWindows) return bindWinsock(addr);
        var stdAddr = addr.toStd(null);
        const server = try stdAddr.listen(io, .{ .reuse_address = true });
        return .{
            .inner = .{ .stream = server },
            .address = server.socket.address,
            .boundPort = switch (server.socket.address) {
                .ip4 => |v| v.port,
                .ip6 => |v| v.port,
            },
            .family = addr.family,
        };
    }

    fn bindWinsock(addr: *const addressMod.Address) !Listener {
        ws.startup();
        const family: i32 = if (addr.family == .ip4) ws.AF_INET else ws.AF_INET6;
        const sock = ws.socket(family, ws.SOCK_STREAM, ws.IPPROTO_TCP);
        if (sock == ws.INVALID_SOCKET) return error.AddressInUse;
        errdefer _ = ws.closesocket(sock);

        const reuse: c_int = 1;
        _ = ws.setsockopt(sock, ws.SOL_SOCKET, ws.SO_REUSEADDR, &reuse, @sizeOf(c_int));
        var actualPort = addr.port;
        if (addr.family == .ip4) {
            var native = ws.sockaddrIn{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes[0..4].*,
            };
            if (ws.bind(sock, &native, @sizeOf(ws.sockaddrIn)) == ws.SOCKET_ERROR) return error.AddressInUse;
            if (ws.listen(sock, ws.SOMAXCONN) == ws.SOCKET_ERROR) return error.AddressInUse;
            if (addr.port == 0) {
                var len: i32 = @sizeOf(ws.sockaddrIn);
                if (ws.getsockname(sock, &native, &len) == ws.SOCKET_ERROR) return error.AddressInUse;
                actualPort = std.mem.bigToNative(u16, native.port);
            }
        } else {
            var native = ws.sockaddrIn6{
                .family = @intCast(ws.AF_INET6),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes,
                .scopeId = addr.zone,
            };
            if (ws.bind(sock, &native, @sizeOf(ws.sockaddrIn6)) == ws.SOCKET_ERROR) return error.AddressInUse;
            if (ws.listen(sock, ws.SOMAXCONN) == ws.SOCKET_ERROR) return error.AddressInUse;
            if (addr.port == 0) {
                var len: i32 = @sizeOf(ws.sockaddrIn6);
                if (ws.getsockname(sock, &native, &len) == ws.SOCKET_ERROR) return error.AddressInUse;
                actualPort = std.mem.bigToNative(u16, native.port);
            }
        }

        return .{
            .inner = .{ .winsock = sock },
            .address = addr.toStd(actualPort),
            .boundPort = actualPort,
            .family = addr.family,
        };
    }

    pub fn localPort(self: *const Listener) u16 {
        return self.boundPort;
    }

    /// Accepts a connection.
    pub fn accept(self: *Listener, io: std.Io) !Socket {
        return switch (self.inner) {
            .winsock => |s| blk: {
                if (!isWindows) unreachable;
                const conn = ws.accept(s, null, null);
                if (conn == ws.INVALID_SOCKET) return error.AcceptFailed;
                break :blk Socket.fromWinsock(conn, io);
            },
            .stream => |*server| blk: {
                const conn = server.accept(io) catch return error.AcceptFailed;
                break :blk Socket.init(conn, io);
            },
        };
    }

    /// Closes the listening socket. Idempotent; wakes a concurrent accept().
    pub fn close(self: *Listener, io: std.Io) void {
        if (self.closed) return;
        self.closed = true;
        switch (self.inner) {
            .winsock => |s| if (isWindows) {
                _ = ws.closesocket(s);
            },
            .stream => |*server| server.deinit(io),
        }
    }

    pub fn localAddress(self: *const Listener) net.IpAddress {
        return self.address;
    }
};

// Winsock init

/// Initializes winsock on Windows (no-op elsewhere). Safe to call repeatedly.
pub fn initWinsock() void {
    UploadStream.ensureWinsock();
    if (isWindows) ws.startup();
}

/// Connect a dummy socket to the listening port to wake any blocked accept()
/// call naturally across all platforms (Windows, Linux, macOS) so the accept
/// thread exits without hanging or triggering runtime teardown race conditions.
pub fn wakeListenerPort(port: u16) void {
    if (isWindows) {
        initWinsock();
        const sock = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
        if (sock == ws.INVALID_SOCKET) return;
        var sa = ws.sockaddrIn{
            .family = @intCast(ws.AF_INET),
            .port = @byteSwap(port),
            .addr = .{ 127, 0, 0, 1 },
        };
        _ = ws.connect(sock, &sa, @sizeOf(ws.sockaddrIn));
        _ = ws.closesocket(sock);
    } else {
        const fd = std.c.socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.STREAM), 0);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = (@as([8]u8, @splat(0))),
        };
        _ = std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    }
}

// Connect

/// Connect to a parsed Address (IPv4 or IPv6).
///
/// On Windows: uses ws232 directly to avoid netConnectIpWindows which maps
/// STATUS_CONNECTION_REFUSED → error.Unexpected → unexpectedStatus() stderr
/// output that corrupts the --listen=- test runner binary protocol.
///
/// On other platforms: uses std.Io.net (existing behaviour).
///
/// For TLS connections (which require an AFD handle), use connectAddressStream().
pub fn connectAddress(io: std.Io, addr: *const addressMod.Address) ConnectError!Socket {
    if (isWindows) {
        initWinsock();
        return connectAddressWindows(io, addr);
    }
    const stdAddr = addr.toStd(null);
    const stream = stdAddr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
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

/// Connect using std.Io.net (always produces a stream-variant Socket with an
/// AFD handle). Required for TLS connections, which must have an AFD-backed
/// socket handle to initialize std.Io.net stream readers/writers.
///
/// On Windows this goes through netConnectIpWindows. It is safe for TLS
/// because TLS connection targets are reachable (we don't test TLS to port 1)
/// and the STATUS_CONNECTION_REFUSED path is never exercised.
pub fn connectAddressStream(io: std.Io, addr: *const addressMod.Address) ConnectError!Socket {
    const stdAddr = addr.toStd(null);
    const stream = stdAddr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
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

/// Windows-native connect: uses ws232.socket() + ws232.connect() directly.
/// No AFD / NTSTATUS path involved → no unexpectedStatus() side effects.
fn connectAddressWindows(io: std.Io, addr: *const addressMod.Address) ConnectError!Socket {
    if (!isWindows) unreachable;

    switch (addr.family) {
        .ip4 => {
            const h = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) {
                return ws.mapConnectError();
            }
            var sa = ws.sockaddrIn{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes[0..4].*,
            };
            if (ws.connect(h, &sa, @sizeOf(ws.sockaddrIn)) == ws.SOCKET_ERROR) {
                // Read the error BEFORE closesocket (see connectIPv4).
                const err = ws.mapConnectError();
                _ = ws.closesocket(h);
                return err;
            }
            ws.applyTimeouts(h);
            return Socket.fromWinsock(h, io);
        },
        .ip6 => {
            const h = ws.socket(ws.AF_INET6, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) return ws.mapConnectError();
            var sa = ws.sockaddrIn6{
                .family = @intCast(ws.AF_INET6),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes,
                .scopeId = addr.zone,
            };
            if (ws.connect(h, &sa, @sizeOf(ws.sockaddrIn6)) == ws.SOCKET_ERROR) {
                // Read the error BEFORE closesocket (see connectIPv4).
                const err = ws.mapConnectError();
                _ = ws.closesocket(h);
                return err;
            }
            ws.applyTimeouts(h);
            return Socket.fromWinsock(h, io);
        },
    }
}

/// Connect to an IP-literal host string (dotted quad or IPv6 text).
/// Hostnames require DNS resolution first (see net/dns.zig).
pub fn connect(io: std.Io, host: []const u8, port: u16) ConnectError!Socket {
    var holder = addressMod.Address{ .family = .ip4, .port = 0 };
    var addr = holder.parseIp(host) catch return ConnectError.HostUnreachable;
    addr.port = port;
    return connectAddress(io, &addr);
}

// Tests

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

    var a = addressMod.Address.loopback6(0);
    var l = Listener.bindAddress(ctx.io, &a) catch return; // skips on no-IPv6 hosts
    defer l.close(ctx.io);
    const port = l.localPort();
    try std.testing.expectEqual(addressMod.Family.ip6, l.family);

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

    var holder = addressMod.Address{ .family = .ip4, .port = 0 };
    var dst = holder.parseIp("::1") catch return;
    dst.port = port;

    var s = connectAddress(ctx.io, &dst) catch return;
    defer s.close();
    try s.writeAll("v6");
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqualStrings("v6", buf[0..n]);
}
