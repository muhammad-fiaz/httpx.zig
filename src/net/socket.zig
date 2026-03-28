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
const address = @import("address.zig");

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

/// Shutdown direction for a connected TCP socket.
pub const ShutdownMode = enum {
    recv,
    send,
    both,
};

fn toPosixShutdownHow(mode: ShutdownMode) posix.ShutdownHow {
    return switch (mode) {
        .recv => .recv,
        .send => .send,
        .both => .both,
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
        const p = parent(r);
        if (bufs.len == 0) return 0;
        const buf = bufs[0];
        const n = p.socket.recv(buf) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        return n;
    }

    fn rebase(_: *Io.Reader, _: usize) Io.Reader.RebaseError!void {
        // Sockets are not seekable; nothing to do.
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

    fn drain(w: *Io.Writer, bufs: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p = parent(w);
        var total_sent: usize = 0;

        const buffered = w.buffered();
        // std.debug.print("drain called: buffered.len={}, bufs.len={}, splat={}\n", .{buffered.len, bufs.len, splat});
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

    fn sendFile(w: *Io.Writer, file_reader: *std.fs.File.Reader, limit: Io.Limit) Io.Writer.FileAllError!usize {
        const p = parent(w);

        var total: usize = 0;
        const max_limit = limit.toInt() orelse std.math.maxInt(usize);
        while (total < max_limit) {
            const remaining = max_limit - total;
            const chunk_len = @min(w.buffer.len, remaining);
            if (chunk_len == 0) break;

            const n_read = file_reader.file.read(w.buffer[0..chunk_len]) catch return error.ReadFailed;
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
        const handle = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        return .{ .handle = handle };
    }

    /// Creates a new IPv6 TCP socket.
    pub fn createV6() !Self {
        try init();
        const handle = try posix.socket(posix.AF.INET6, posix.SOCK.STREAM, 0);
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

    /// Resolves and connects to `host:port`.
    pub fn connectHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(host, port);
        try self.connect(addr);
    }

    /// Parses and connects an endpoint like `host:port`.
    pub fn connectEndpoint(self: *Self, endpoint: []const u8, default_port: u16) !void {
        const parsed = try address.parseHostPort(endpoint, default_port);
        try self.connectHost(parsed.host, parsed.port);
    }

    /// Sends data through the socket, returning bytes sent.
    pub fn send(self: *Self, data: []const u8) !usize {
        return posix.send(self.handle, data, 0);
    }

    /// Compatibility alias for stream-style write APIs.
    pub fn write(self: *Self, data: []const u8) !usize {
        return self.send(data);
    }

    /// Sends all data, blocking until complete.
    pub fn sendAll(self: *Self, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += try self.send(data[sent..]);
        }
    }

    /// Compatibility alias for stream-style write-all APIs.
    pub fn writeAll(self: *Self, data: []const u8) !void {
        return self.sendAll(data);
    }

    /// Receives data into the buffer, returning bytes received.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        if (is_windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc = ws2_32.recv(
                self.handle,
                @ptrCast(buffer.ptr),
                @intCast(buffer.len),
                0,
            );
            if (rc == ws2_32.SOCKET_ERROR) return error.RecvFailed;
            return @intCast(rc);
        }

        return posix.recv(self.handle, buffer, 0);
    }

    /// Compatibility alias for stream-style read APIs.
    pub fn read(self: *Self, buffer: []u8) !usize {
        return self.recv(buffer);
    }

    /// Sets a socket option.
    pub fn setOption(self: *Self, level: u32, optname: u32, value: []const u8) !void {
        try posix.setsockopt(self.handle, level, optname, value);
    }

    /// Enables or disables TCP_NODELAY (Nagle's algorithm).
    pub fn setNoDelay(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.IPPROTO.TCP, tcpNoDelayOption(), std.mem.asBytes(&value));
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

    /// Sets the receive buffer size in bytes.
    pub fn setRecvBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&value));
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

    /// Sets the send buffer size in bytes.
    pub fn setSendBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&value));
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

    /// Resolves and binds to `host:port`.
    pub fn bindHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(host, port);
        try self.bind(addr);
    }

    /// Starts listening for connections.
    pub fn listen(self: *Self, backlog: u31) !void {
        try posix.listen(self.handle, backlog);
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !AcceptResult {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const accept_params_len = comptime @typeInfo(@TypeOf(posix.accept)).@"fn".params.len;
        const handle = if (accept_params_len == 4)
            try posix.accept(self.handle, &addr, &addr_len, 0)
        else
            try posix.accept(self.handle, &addr, &addr_len);
        return .{
            .socket = Socket.fromHandle(handle),
            .addr = net.Address{ .any = addr },
        };
    }

    /// Shuts down one or both halves of the connection.
    pub fn shutdown(self: *Self, mode: ShutdownMode) !void {
        try posix.shutdown(self.handle, toPosixShutdownHow(mode));
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

    /// Returns the local address the socket is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns the connected peer address.
    pub fn getPeerAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getpeername(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns a reader interface for the socket.
    pub fn reader(self: *Self) std.io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = struct {
                fn read(ctx: *const anyopaque, buffer: []u8) !usize {
                    const s: *Socket = @ptrCast(@alignCast(@constCast(ctx)));
                    return s.recv(buffer);
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
                    const s: *Socket = @ptrCast(@alignCast(@constCast(ctx)));
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
        return initWithBacklog(addr, 128);
    }

    /// Resolves and creates a TCP listener for `host:port`.
    pub fn initHost(host: []const u8, port: u16) !Self {
        const addr = try address.resolve(host, port);
        return Self.init(addr);
    }

    /// Creates and binds a TCP listener to the address with explicit backlog.
    pub fn initWithBacklog(addr: net.Address, backlog: u31) !Self {
        var socket = try Socket.createForAddress(addr);
        errdefer socket.close();

        try socket.setReuseAddr(true);
        try socket.bind(addr);
        try socket.listen(backlog);

        return .{ .socket = socket };
    }

    /// Resolves and creates a TCP listener for `host:port` with explicit backlog.
    pub fn initHostWithBacklog(host: []const u8, port: u16, backlog: u31) !Self {
        const addr = try address.resolve(host, port);
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

    /// Creates a UDP socket using the address family of the provided address.
    pub fn createForAddress(addr: net.Address) !Self {
        try init();
        const handle = try posix.socket(addr.any.family, posix.SOCK.DGRAM, 0);
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

    /// Resolves and binds to `host:port`.
    pub fn bindHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(host, port);
        try self.bind(addr);
    }

    /// Connects the UDP socket to a default peer address.
    /// After calling this, `send`/`recv` operate on that peer.
    pub fn connect(self: *Self, addr: net.Address) !void {
        try posix.connect(self.handle, &addr.any, addr.getOsSockLen());
        self.connected = true;
    }

    /// Resolves and connects to `host:port`.
    pub fn connectHost(self: *Self, host: []const u8, port: u16) !void {
        const addr = try address.resolve(host, port);
        try self.connect(addr);
    }

    /// Parses and connects an endpoint like `host:port`.
    pub fn connectEndpoint(self: *Self, endpoint: []const u8, default_port: u16) !void {
        const parsed = try address.parseHostPort(endpoint, default_port);
        try self.connectHost(parsed.host, parsed.port);
    }

    /// Sends a datagram to the connected peer.
    pub fn send(self: *Self, data: []const u8) !usize {
        return posix.send(self.handle, data, 0);
    }

    /// Compatibility alias for stream-style write APIs.
    pub fn write(self: *Self, data: []const u8) !usize {
        return self.send(data);
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

    /// Resolves destination host and sends a datagram.
    pub fn sendToHost(self: *Self, host: []const u8, port: u16, data: []const u8) !usize {
        const addr = try address.resolve(host, port);
        return self.sendTo(addr, data);
    }

    /// Receives a datagram from the connected peer.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        if (is_windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc = ws2_32.recv(
                self.handle,
                @ptrCast(buffer.ptr),
                @intCast(buffer.len),
                0,
            );
            if (rc == ws2_32.SOCKET_ERROR) return UdpError.RecvFailed;
            return @intCast(rc);
        }

        return posix.recv(self.handle, buffer, 0);
    }

    /// Compatibility alias for stream-style read APIs.
    pub fn read(self: *Self, buffer: []u8) !usize {
        return self.recv(buffer);
    }

    /// Receives a datagram and returns the source address.
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { n: usize, addr: net.Address } {
        var addr: posix.sockaddr = undefined;
        if (comptime builtin.os.tag == .windows) {
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

    /// Enables or disables UDP broadcast.
    pub fn setBroadcast(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&value));
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

    /// Sets the receive buffer size in bytes.
    pub fn setRecvBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&value));
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

    /// Sets the send buffer size in bytes.
    pub fn setSendBufferSize(self: *Self, bytes: usize) !void {
        const value: i32 = @intCast(@min(bytes, @as(usize, std.math.maxInt(i32))));
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&value));
    }

    /// Returns the local address the socket is bound to.
    pub fn getLocalAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.handle, &addr, &addr_len);
        return net.Address{ .any = addr };
    }

    /// Returns the connected peer address.
    pub fn getPeerAddress(self: *Self) !net.Address {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getpeername(self.handle, &addr, &addr_len);
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
    const recv_buf_ptr: *const fn (*Socket, usize) anyerror!void = Socket.setRecvBufferSize;
    const send_buf_ptr: *const fn (*Socket, usize) anyerror!void = Socket.setSendBufferSize;

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
