//! Cross-Platform Socket Abstraction for httpx.zig
//!
//! Provides a unified socket interface for TCP networking across platforms:
//!
//! - Windows (Winsock2) and POSIX systems
//! - TCP client and server socket operations
//! - Configurable timeouts and socket options
//! - Reader/Writer interfaces for streaming

const std = @import("std");
const net = std.net;
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const INVALID_SOCKET: posix.socket_t = if (is_windows)
    @ptrFromInt(~@as(usize, 0))
else
    -1;

pub const UdpError = error{
    SendFailed,
    RecvFailed,
};

pub const NetInitError = error{InitializationError};

/// Initializes the platform networking subsystem.
///
/// On Windows this calls `WSAStartup`; on other platforms it is a no-op.
pub fn init() NetInitError!void {
    if (!is_windows) return;

    // Zig's std.posix APIs usually handle WSA initialization internally, but we
    // expose this for explicit control and compatibility with other networking code.
    if (@hasDecl(std.os.windows, "WSAStartup")) {
        _ = std.os.windows.WSAStartup(2, 2) catch return error.InitializationError;
    }
}

/// Deinitializes the platform networking subsystem.
///
/// On Windows this calls `WSACleanup`; on other platforms it is a no-op.
pub fn deinit() void {
    if (!is_windows) return;
    if (@hasDecl(std.os.windows, "WSACleanup")) {
        _ = std.os.windows.WSACleanup() catch return;
    }
}

/// Adapter that exposes a `std.Io.Reader` backed by a connected `Socket`.
///
/// This is primarily used to integrate with `std.crypto.tls.Client`.
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

    fn stream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var bufs: [1][]u8 = .{dest};
        const n = try readVec(io_r, &bufs);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const p = parent(io_r);
        if (is_windows) {
            const windows = std.os.windows;
            var iovecs: [max_buffers_len]windows.ws2_32.WSABUF = undefined;
            const bufs_n, const data_size = try io_r.writableVectorWsa(&iovecs, data);
            const bufs = iovecs[0..bufs_n];
            if (bufs.len == 0 or bufs[0].len == 0) return 0;

            var flags: u32 = 0;
            var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
            var n: u32 = undefined;

            if (windows.ws2_32.WSARecv(
                p.socket.handle,
                bufs.ptr,
                @intCast(bufs.len),
                &n,
                &flags,
                &overlapped,
                null,
            ) == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSA_IO_PENDING => {
                        var result_flags: u32 = undefined;
                        if (windows.ws2_32.WSAGetOverlappedResult(
                            p.socket.handle,
                            &overlapped,
                            &n,
                            windows.TRUE,
                            &result_flags,
                        ) == windows.FALSE) return error.ReadFailed;
                    },
                    else => return error.ReadFailed,
                }
            }

            if (n == 0) return error.EndOfStream;
            if (n > data_size) {
                io_r.end += n - data_size;
                return data_size;
            }
            return n;
        } else {
            var bufs: [max_buffers_len][]u8 = undefined;
            const bufs_n, const data_size = try io_r.writableVector(&bufs, data);
            const real_bufs = bufs[0..bufs_n];
            if (real_bufs.len == 0 or real_bufs[0].len == 0) return 0;

            const n = p.socket.recv(real_bufs[0]) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            if (n > data_size) {
                io_r.end += n - data_size;
                return data_size;
            }
            return n;
        }
    }

    const max_buffers_len = 8;

    fn rebase(_: *Io.Reader, _: usize) Io.Reader.RebaseError!void {
        // Sockets are not seekable; nothing to do.
    }

    const vtable: Io.Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
        .rebase = rebase,
    };
};

/// Adapter that exposes a `std.Io.Writer` backed by a connected `Socket`.
///
/// This is primarily used to integrate with `std.crypto.tls.Client`.
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

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p = parent(w);
        const buffered = w.buffered();
        var total_sent: usize = 0;

        // 1. Send existing buffered data.
        if (buffered.len > 0) {
            p.socket.sendAll(buffered) catch return error.WriteFailed;
            total_sent += buffered.len;
        }

        // 2. Send the non-splat data slices.
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len > 0) {
                p.socket.sendAll(bytes) catch return error.WriteFailed;
                total_sent += bytes.len;
            }
        }

        // 3. Send the last element (pattern) repeated `splat` times.
        const pattern = data[data.len - 1];
        if (pattern.len > 0) {
            for (0..splat) |_| {
                p.socket.sendAll(pattern) catch return error.WriteFailed;
                total_sent += pattern.len;
            }
        }

        return w.consume(total_sent);
    }

    fn sendFile(_: *Io.Writer, _: *std.fs.File.Reader, _: Io.Limit) Io.Writer.FileError!usize {
        return error.Unimplemented;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        return Io.Writer.defaultFlush(w);
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

    /// Creates a new TCP socket.
    pub fn create() !Self {
        try init();
        const handle = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new TCP socket using the address family of the provided address.
    pub fn createForAddress(addr: net.Address) !Self {
        try init();
        const handle = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a socket from an existing handle.
    pub fn fromHandle(handle: posix.socket_t) Self {
        return .{ .handle = handle, .connected = true };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        if (self.isValid()) {
            posix.close(self.handle);
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
        try posix.connect(self.handle, &addr.any, addr.getOsSockLen());
        self.connected = true;
    }

    /// Sends data through the socket, returning bytes sent.
    pub fn send(self: *Self, data: []const u8) !usize {
        return posix.send(self.handle, data, 0);
    }

    /// Sends all data, blocking until complete.
    pub fn sendAll(self: *Self, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += try self.send(data[sent..]);
        }
    }

    /// Receives data into the buffer, returning bytes received.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        return posix.recv(self.handle, buffer, 0);
    }

    /// Sets a socket option.
    pub fn setOption(self: *Self, level: u32, optname: u32, value: []const u8) !void {
        try posix.setsockopt(self.handle, level, optname, value);
    }

    /// Enables or disables TCP_NODELAY (Nagle's algorithm).
    pub fn setNoDelay(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the send timeout in milliseconds.
    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Enables or disables keep-alive probes.
    pub fn setKeepAlive(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&value));
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }

    /// Binds the socket to an address.
    pub fn bind(self: *Self, addr: net.Address) !void {
        try posix.bind(self.handle, &addr.any, addr.getOsSockLen());
    }

    /// Starts listening for connections.
    pub fn listen(self: *Self, backlog: u31) !void {
        try posix.listen(self.handle, backlog);
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !struct { socket: Socket, addr: net.Address } {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const handle = try posix.accept(self.handle, &addr, &addr_len);
        return .{
            .socket = Socket.fromHandle(handle),
            .addr = net.Address{ .any = addr },
        };
    }

    /// Returns a reader interface for the socket.
    pub fn reader(self: *Self) std.io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = struct {
                fn read(ctx: *const anyopaque, buffer: []u8) !usize {
                    const s: *Socket = @ptrCast(@constCast(ctx));
                    return s.recv(buffer) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => err,
                    };
                }
            }.read,
        };
    }

    /// Returns a writer interface for the socket.
    pub fn writer(self: *Self) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = struct {
                fn write(ctx: *const anyopaque, data: []const u8) !usize {
                    const s: *Socket = @ptrCast(@constCast(ctx));
                    return s.send(data);
                }
            }.write,
        };
    }
};

/// TCP listener for accepting incoming connections.
pub const TcpListener = struct {
    socket: Socket,

    const Self = @This();

    /// Creates and binds a TCP listener to the address.
    pub fn init(addr: net.Address) !Self {
        var socket = try Socket.createForAddress(addr);
        errdefer socket.close();

        try socket.setReuseAddr(true);
        try socket.bind(addr);
        try socket.listen(128);

        return .{ .socket = socket };
    }

    /// Closes the listener.
    pub fn deinit(self: *Self) void {
        self.socket.close();
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !struct { socket: Socket, addr: net.Address } {
        return self.socket.accept();
    }

    /// Returns the local address the listener is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.socket.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
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
        const handle = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new UDP socket for IPv6.
    pub fn createV6() !Self {
        try init();
        const handle = try posix.socket(posix.AF.INET6, posix.SOCK.DGRAM, 0);
        return .{ .handle = handle };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        if (self.isValid()) {
            posix.close(self.handle);
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
        try posix.bind(self.handle, &addr.any, addr.getOsSockLen());
    }

    /// Connects the UDP socket to a default peer address.
    /// After calling this, `send`/`recv` operate on that peer.
    pub fn connect(self: *Self, addr: net.Address) !void {
        try posix.connect(self.handle, &addr.any, addr.getOsSockLen());
        self.connected = true;
    }

    /// Sends a datagram to the connected peer.
    pub fn send(self: *Self, data: []const u8) !usize {
        return posix.send(self.handle, data, 0);
    }

    /// Sends a datagram to a specific address.
    pub fn sendTo(self: *Self, addr: net.Address, data: []const u8) !usize {
        if (is_windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc = ws2_32.sendto(
                self.handle,
                @ptrCast(data.ptr),
                @intCast(data.len),
                0,
                @ptrCast(&addr.any),
                @intCast(addr.getOsSockLen()),
            );
            if (rc == ws2_32.SOCKET_ERROR) return UdpError.SendFailed;
            return @intCast(rc);
        }

        return posix.sendto(self.handle, data, 0, &addr.any, addr.getOsSockLen());
    }

    /// Receives a datagram from the connected peer.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        return posix.recv(self.handle, buffer, 0);
    }

    /// Receives a datagram and returns the source address.
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { n: usize, addr: net.Address } {
        var addr: posix.sockaddr = undefined;
        if (is_windows) {
            const ws2_32 = std.os.windows.ws2_32;
            var addr_len: i32 = @intCast(@sizeOf(posix.sockaddr));
            const rc = ws2_32.recvfrom(
                self.handle,
                @ptrCast(buffer.ptr),
                @intCast(buffer.len),
                0,
                @ptrCast(&addr),
                &addr_len,
            );
            if (rc == ws2_32.SOCKET_ERROR) return UdpError.RecvFailed;
            return .{ .n = @intCast(rc), .addr = net.Address{ .any = addr } };
        } else {
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const n = try posix.recvfrom(self.handle, buffer, 0, &addr, &addr_len);
            return .{ .n = n, .addr = net.Address{ .any = addr } };
        }
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the send timeout in milliseconds.
    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Returns the local address the socket is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.handle, &addr, &addr_len);
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
