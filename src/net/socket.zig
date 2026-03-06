//! Cross-Platform Socket Abstraction for httpx.zig
//!
//! Provides a unified socket interface for TCP networking across platforms:
//!
//! - Windows (Winsock2) and POSIX systems
//! - TCP client and server socket operations
//! - Configurable timeouts and socket options
//! - Reader/Writer interfaces for streaming

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const net = Io.net;

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

/// Returns a blocking single-threaded Io instance.
pub fn getIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Adapter that exposes a `std.Io.Reader` backed by a connected `Socket`.
///
/// This is primarily used to integrate with `std.crypto.tls.Client`.
pub const SocketIoReader = struct {
    socket: *Socket,
    reader: Io.Reader,

    pub fn initFromSocket(socket: *Socket, buffer: []u8) SocketIoReader {
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

        while (total < limit.toInt(usize)) {
            const max_to_read = @min(r.buffer.len, limit.toInt(usize) - total);
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

    fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.StreamRemainingError!usize {
        var total: usize = 0;

        while (total < limit.toInt(usize)) {
            const max_to_read = @min(r.buffer.len, limit.toInt(usize) - total);
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

    pub fn initFromSocket(socket: *Socket, buffer: []u8) SocketIoWriter {
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

    fn drain(w: *Io.Writer, bufs: []const []const u8, start_index: usize) Io.Writer.Error!usize {
        const p = parent(w);
        var i: usize = start_index;
        while (i < bufs.len and bufs[i].len == 0) : (i += 1) {}
        if (i >= bufs.len) return 0;

        const n = p.socket.send(bufs[i]) catch return error.WriteFailed;
        return n;
    }

    fn sendFile(w: *Io.Writer, file_reader: *std.fs.File.Reader, limit: Io.Limit) Io.Writer.FileAllError!usize {
        const p = parent(w);

        var total: usize = 0;
        while (total < limit.toInt(usize)) {
            const remaining = limit.toInt(usize) - total;
            const chunk_len = @min(w.buffer.len, remaining);
            if (chunk_len == 0) break;

            const n_read = file_reader.read(w.buffer[0..chunk_len]) catch return error.ReadFailed;
            if (n_read == 0) break;

            p.socket.sendAll(w.buffer[0..n_read]) catch return error.WriteFailed;
            total += n_read;
        }

        return total;
    }

    fn flush(_: *Io.Writer) Io.Writer.Error!void {
        // No-op for blocking sockets.
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
///
/// In Zig 0.16, this wraps the new `std.Io.net` API. A Socket represents
/// a connected TCP stream.
pub const Socket = struct {
    stream: net.Stream,
    io: Io,
    connected: bool = false,

    const Self = @This();

    /// Connects to the specified address and returns a new Socket.
    pub fn connectTo(address: net.IpAddress) !Self {
        const io = getIo();
        const stream = address.connect(io, .{ .mode = .stream }) catch return error.ConnectionFailed;
        return .{ .stream = stream, .io = io, .connected = true };
    }

    /// Creates a socket from an existing stream.
    pub fn fromStream(stream: net.Stream, io: Io) Self {
        return .{ .stream = stream, .io = io, .connected = true };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        if (self.connected) {
            self.stream.close(self.io);
            self.connected = false;
        }
    }

    /// Returns true if the socket is connected.
    pub fn isValid(self: *const Self) bool {
        return self.connected;
    }

    /// Returns the underlying OS handle for socket options.
    pub fn getHandle(self: *const Self) net.Socket.Handle {
        return self.stream.socket.handle;
    }

    /// Sends data through the socket, returning bytes sent.
    pub fn send(self: *Self, data: []const u8) !usize {
        // Use the stream writer for sending
        var write_buf: [16 * 1024]u8 = undefined;
        var sw = self.stream.writer(self.io, &write_buf);
        const n = sw.interface.write(data) catch return error.SendFailed;
        sw.interface.flush() catch return error.SendFailed;
        return n;
    }

    /// Sends all data, blocking until complete.
    pub fn sendAll(self: *Self, data: []const u8) !void {
        var write_buf: [16 * 1024]u8 = undefined;
        var sw = self.stream.writer(self.io, &write_buf);
        sw.interface.writeAll(data) catch return error.SendFailed;
        sw.interface.flush() catch return error.SendFailed;
    }

    /// Receives data into the buffer, returning bytes received.
    pub fn recv(self: *Self, buffer: []u8) !usize {
        var read_buf: [16 * 1024]u8 = undefined;
        var sr = self.stream.reader(self.io, &read_buf);
        var iov = [_][]u8{buffer};
        const n = sr.interface.readVec(&iov) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return error.RecvFailed,
        };
        return n;
    }

    /// Enables or disables TCP_NODELAY (Nagle's algorithm).
    pub fn setNoDelay(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.getHandle(), posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the send timeout in milliseconds.
    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Enables or disables keep-alive probes.
    pub fn setKeepAlive(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&value));
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.getHandle(), posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }
};

/// TCP listener for accepting incoming connections.
pub const TcpListener = struct {
    server: net.Server,
    io: Io,

    const Self = @This();

    /// Creates and binds a TCP listener to the address.
    pub fn listenOn(address: net.IpAddress) !Self {
        const io = getIo();
        const server = address.listen(io, .{
            .reuse_address = true,
        }) catch return error.ListenFailed;
        return .{ .server = server, .io = io };
    }

    /// Closes the listener.
    pub fn closeListener(self: *Self) void {
        self.server.deinit(self.io);
    }

    /// Accepts an incoming connection.
    pub fn acceptConnection(self: *Self) !Socket {
        const stream = self.server.accept(self.io) catch return error.AcceptFailed;
        return Socket.fromStream(stream, self.io);
    }
};

/// UDP datagram socket abstraction.
pub const UdpSocket = struct {
    socket: net.Socket,
    io: Io,
    connected: bool = false,

    const Self = @This();

    /// Creates and binds a UDP socket to the specified address.
    pub fn bindTo(address: net.IpAddress) !Self {
        const io = getIo();
        const sock = net.IpAddress.bind(&address, io, .{
            .mode = .dgram,
        }) catch return error.BindFailed;
        return .{ .socket = sock, .io = io };
    }

    /// Closes the socket and releases resources.
    pub fn close(self: *Self) void {
        self.socket.close(self.io);
    }

    /// Returns true if the socket is valid.
    pub fn isValid(self: *const Self) bool {
        _ = self;
        return true;
    }

    /// Sends a datagram to a specific address.
    pub fn sendTo(self: *Self, dest: *const net.IpAddress, data: []const u8) !usize {
        self.socket.send(self.io, dest, data) catch return UdpError.SendFailed;
        return data.len;
    }

    /// Receives a datagram and returns the source address.
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { n: usize, addr: net.IpAddress } {
        const msg = self.socket.receive(self.io, buffer) catch return UdpError.RecvFailed;
        return .{ .n = msg.data.len, .addr = msg.from };
    }

    /// Enables or disables address reuse.
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const value: u32 = if (enable) 1 else 0;
        try posix.setsockopt(self.socket.handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&value));
    }

    /// Sets the receive timeout in milliseconds.
    pub fn setRecvTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.socket.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.socket.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        }
    }

    /// Sets the send timeout in milliseconds.
    pub fn setSendTimeout(self: *Self, ms: u64) !void {
        if (is_windows) {
            const value_ms: u32 = @intCast(@min(ms, @as(u64, std.math.maxInt(u32))));
            try posix.setsockopt(self.socket.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&value_ms));
        } else {
            const tv = posix.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast((ms % 1000) * 1000),
            };
            try posix.setsockopt(self.socket.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        }
    }
};

test "Socket connect and close" {
    // Create a listener first to have something to connect to
    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try TcpListener.listenOn(addr);
    defer listener.closeListener();

    // Get the assigned port
    const listen_addr = listener.server.socket.address;

    var socket = try Socket.connectTo(listen_addr);
    defer socket.close();
    try std.testing.expect(socket.isValid());
}

test "TcpListener accept" {
    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try TcpListener.listenOn(addr);
    defer listener.closeListener();

    const listen_addr = listener.server.socket.address;

    // Connect a client
    var client = try Socket.connectTo(listen_addr);
    defer client.close();

    // Accept the connection
    var accepted = try listener.acceptConnection();
    defer accepted.close();

    try std.testing.expect(accepted.isValid());
}

test "UdpSocket send/recv localhost" {
    const recv_addr = try net.IpAddress.parse("127.0.0.1", 0);
    var recv_sock = try UdpSocket.bindTo(recv_addr);
    defer recv_sock.close();

    const bound_addr = recv_sock.socket.address;

    const send_addr = try net.IpAddress.parse("127.0.0.1", 0);
    var send_sock = try UdpSocket.bindTo(send_addr);
    defer send_sock.close();

    const msg = "ping";
    _ = try send_sock.sendTo(&bound_addr, msg);

    var buf: [32]u8 = undefined;
    const got = try recv_sock.recvFrom(&buf);
    try std.testing.expectEqualStrings(msg, buf[0..got.n]);
}
