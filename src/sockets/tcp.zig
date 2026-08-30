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
// ws2_32.connect() directly. WSAECONNREFUSED (10061) is properly mapped to
// ConnectError.ConnectionRefused with no side effects. Socket.read/write/close
// also use ws2_32 directly on Windows so the same handle type works end-to-end.
// On other platforms the existing std.Io.net path is unchanged.

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const address_mod = @import("../net/address.zig");
const posix = std.posix;
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

// Windows winsock shims
// All declared inside a comptime block so they compile to nothing on non-Windows.

const ws = if (is_windows) struct {
    pub const SOCKET = usize;
    pub const SOCKET_ERROR: i32 = -1;
    pub const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
    pub const AF_INET: i32 = 2;
    pub const AF_INET6: i32 = 23;
    pub const SOCK_STREAM: i32 = 1;
    pub const IPPROTO_TCP: i32 = 6;

    pub const sockaddr_in = extern struct {
        family: u16,
        port: u16, // big-endian
        addr: [4]u8,
        zero: [8]u8 = .{0} ** 8,
    };

    pub const sockaddr_in6 = extern struct {
        family: u16,
        port: u16, // big-endian
        flowinfo: u32 = 0,
        addr: [16]u8,
        scope_id: u32 = 0,
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
    pub extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.c) SOCKET;
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

    var wsa_done = std.atomic.Value(bool).init(false);

    pub fn startup() void {
        if (wsa_done.swap(true, .acq_rel)) return;
        var data: WSADATA = undefined;
        _ = WSAStartup(0x0202, &data);
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
pub fn setTimeouts(sock: net.Socket.Handle, timeout_ms: u31) void {
    if (is_windows) {
        const ms: u32 = @intCast(timeout_ms);
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_RCVTIMEO, &ms, 4);
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_SNDTIMEO, &ms, 4);
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
pub fn setNoDelay(sock: net.Socket.Handle) void {
    const one: c_int = 1;
    if (is_windows) {
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.IPPROTO_TCP_OPT, ws.TCP_NODELAY, &one, @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.IPPROTO.TCP, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY == 1
    }
}

pub fn setKeepAlive(sock: net.Socket.Handle, idle_secs: u32) void {
    const one: c_int = 1;
    if (is_windows) {
        _ = ws.setsockopt(@intCast(@intFromPtr(sock)), ws.SOL_SOCKET, ws.SO_KEEPALIVE, &one, @sizeOf(c_int));
    } else {
        posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
        const idle: c_int = @intCast(idle_secs);
        switch (builtin.os.tag) {
            .linux => posix.setsockopt(sock, posix.IPPROTO.TCP, 4, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPIDLE
            .macos => posix.setsockopt(sock, posix.IPPROTO.TCP, 0x10, std.mem.asBytes(&idle)) catch {}, // TCP_KEEPALIVE
            else => {},
        }
    }
}

// UploadStream
// Used by the HTTP client for large uploads. On Windows, uses ws2_32 directly
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
            const h = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) return ConnectError.ConnectionRefused;
            var addr = ws.sockaddr_in{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, port),
                .addr = host,
            };
            if (ws.connect(h, &addr, @sizeOf(ws.sockaddr_in)) == ws.SOCKET_ERROR) {
                _ = ws.closesocket(h);
                return ws.mapConnectError();
            }
            ws.applyTimeouts(h);
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
            return .{ .handle = @intCast(fd) };
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

// Error sets

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
/// Internally a tagged union: `winsock` (raw ws2_32 SOCKET) or `stream`
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
    close_flag: std.atomic.Value(bool) = .init(false),

    const Inner = union(enum) {
        /// Raw ws2_32 SOCKET — used on Windows for client connections.
        winsock: if (is_windows) ws.SOCKET else void,
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
        return !@constCast(&self.close_flag).swap(true, .acq_rel);
    }

    // Close

    pub fn close(self: *const Socket) void {
        if (!self.acquireClose()) return;
        switch (self.inner) {
            .winsock => |s| if (is_windows) {
                _ = ws.closesocket(s);
            },
            .stream => |st| st.close(self.io),
        }
    }

    /// Signals end-of-stream to the peer without dropping unread data.
    pub fn shutdownWrite(self: *const Socket) void {
        switch (self.inner) {
            .winsock => |s| if (is_windows) {
                _ = ws.shutdown(s, ws.SD_SEND);
            },
            .stream => |st| st.shutdown(self.io, .send) catch {},
        }
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
            .winsock => |s| if (is_windows) {
                _ = ws.closesocket(s);
            },
            .stream => |st| st.close(self.io),
        }
    }

    // I/O

    /// Reads up to buf.len bytes; partial reads are normal.
    pub fn read(self: *const Socket, buf: []u8) ReadError!usize {
        if (buf.len == 0) return 0;
        switch (self.inner) {
            .winsock => |s| {
                if (!is_windows) unreachable;
                const rc = ws.recv(s, buf.ptr, @intCast(@min(buf.len, 65536)), 0);
                if (rc == ws.SOCKET_ERROR) {
                    return switch (ws.WSAGetLastError()) {
                        10054 => ReadError.ConnectionReset, // WSAECONNRESET
                        0 => ReadError.ConnectionClosed,
                        else => ReadError.ReadFailed,
                    };
                }
                if (rc == 0) return 0; // EOF
                return @intCast(rc);
            },
            .stream => |st| {
                var data: [1][]u8 = .{buf};
                const n = self.io.vtable.netRead(self.io.userdata, st.socket.handle, &data) catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.Unexpected => return ReadError.ConnectionReset,
                    else => return ReadError.ReadFailed,
                };
                if (n == 0) return 0; // EOF
                return n;
            },
        }
    }

    fn write(self: *const Socket, data: []const u8) WriteError!usize {
        if (data.len == 0) return 0;
        switch (self.inner) {
            .winsock => |s| {
                if (!is_windows) unreachable;
                const rc = ws.send(s, data.ptr, @intCast(@min(data.len, 65536)), 0);
                if (rc == ws.SOCKET_ERROR) {
                    return switch (ws.WSAGetLastError()) {
                        10054, 10053 => WriteError.ConnectionReset, // WSAECONNRESET, WSAECONNABORTED
                        else => WriteError.WriteFailed,
                    };
                }
                return @intCast(rc);
            },
            .stream => |st| {
                const chunk = data[0..@min(data.len, 4096)];
                const n = self.io.vtable.netWrite(self.io.userdata, st.socket.handle, chunk, &.{""}, 0) catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.Unexpected => return WriteError.ConnectionReset,
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
    server: net.Server,
    bound_port: u16,
    family: address_mod.Family = .ip4,
    closed: bool = false,

    /// Bind 0.0.0.0:port. port=0 lets OS choose an ephemeral port.
    pub fn bind(io: std.Io, port: u16) !Listener {
        var a = address_mod.Address.unspecified4(port);
        return bindAddress(io, &a);
    }

    /// Bind on an explicit Address - enables IPv6 ("::")  listeners.
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

// Winsock init

/// Initializes winsock on Windows (no-op elsewhere). Safe to call repeatedly.
pub fn initWinsock() void {
    UploadStream.ensureWinsock();
    if (is_windows) ws.startup();
}

/// Connect a dummy socket to the listening port to wake any blocked accept()
/// call naturally across all platforms (Windows, Linux, macOS) so the accept
/// thread exits without hanging or triggering runtime teardown race conditions.
pub fn wakeListenerPort(port: u16) void {
    if (is_windows) {
        initWinsock();
        const sock = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
        if (sock == ws.INVALID_SOCKET) return;
        var sa = ws.sockaddr_in{
            .family = @intCast(ws.AF_INET),
            .port = @byteSwap(port),
            .addr = .{ 127, 0, 0, 1 },
        };
        _ = ws.connect(sock, &sa, @sizeOf(ws.sockaddr_in));
        _ = ws.closesocket(sock);
    } else {
        const sock_fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
        defer std.posix.close(sock_fd);
        const sa = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        _ = std.posix.connect(sock_fd, &sa.any, sa.getOsSockLen()) catch {};
    }
}

// Connect

/// Connect to a parsed Address (IPv4 or IPv6).
///
/// On Windows: uses ws2_32 directly to avoid netConnectIpWindows which maps
/// STATUS_CONNECTION_REFUSED → error.Unexpected → unexpectedStatus() stderr
/// output that corrupts the --listen=- test runner binary protocol.
///
/// On other platforms: uses std.Io.net (existing behaviour).
///
/// For TLS connections (which require an AFD handle), use connectAddressStream().
pub fn connectAddress(io: std.Io, addr: *const address_mod.Address) ConnectError!Socket {
    if (is_windows) {
        initWinsock();
        return connectAddressWindows(io, addr);
    }
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

/// Connect using std.Io.net (always produces a stream-variant Socket with an
/// AFD handle). Required for TLS connections, which must have an AFD-backed
/// socket handle to initialize std.Io.net stream readers/writers.
///
/// On Windows this goes through netConnectIpWindows. It is safe for TLS
/// because TLS connection targets are reachable (we don't test TLS to port 1)
/// and the STATUS_CONNECTION_REFUSED path is never exercised.
pub fn connectAddressStream(io: std.Io, addr: *const address_mod.Address) ConnectError!Socket {
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

/// Windows-native connect: uses ws2_32.socket() + ws2_32.connect() directly.
/// No AFD / NTSTATUS path involved → no unexpectedStatus() side effects.
fn connectAddressWindows(io: std.Io, addr: *const address_mod.Address) ConnectError!Socket {
    if (!is_windows) unreachable;

    switch (addr.family) {
        .ip4 => {
            const h = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) return ws.mapConnectError();
            var sa = ws.sockaddr_in{
                .family = @intCast(ws.AF_INET),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes[0..4].*,
            };
            if (ws.connect(h, &sa, @sizeOf(ws.sockaddr_in)) == ws.SOCKET_ERROR) {
                _ = ws.closesocket(h);
                return ws.mapConnectError();
            }
            ws.applyTimeouts(h);
            return Socket.fromWinsock(h, io);
        },
        .ip6 => {
            const h = ws.socket(ws.AF_INET6, ws.SOCK_STREAM, ws.IPPROTO_TCP);
            if (h == ws.INVALID_SOCKET) return ws.mapConnectError();
            var sa = ws.sockaddr_in6{
                .family = @intCast(ws.AF_INET6),
                .port = std.mem.nativeToBig(u16, addr.port),
                .addr = addr.bytes,
                .scope_id = addr.zone,
            };
            if (ws.connect(h, &sa, @sizeOf(ws.sockaddr_in6)) == ws.SOCKET_ERROR) {
                _ = ws.closesocket(h);
                return ws.mapConnectError();
            }
            ws.applyTimeouts(h);
            return Socket.fromWinsock(h, io);
        },
    }
}

/// Connect to an IP-literal host string (dotted quad or IPv6 text).
/// Hostnames require DNS resolution first (see net/dns.zig).
pub fn connect(io: std.Io, host: []const u8, port: u16) ConnectError!Socket {
    var holder = address_mod.Address{ .family = .ip4, .port = 0 };
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
