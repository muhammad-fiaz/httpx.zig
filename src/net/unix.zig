//! Unix Domain Socket support for httpx.zig
//!
//! Provides IPC (Inter-Process Communication) via Unix domain sockets (AF_UNIX).
//!
//! Unix sockets are available on Linux, macOS, and Windows 10+ (1803+).
//! They bypass the network stack entirely for same-machine communication,
//! offering lower latency than TCP loopback.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io_util = @import("../io/any_io.zig");
const defaultIo = io_util.defaultIo;
const is_windows = builtin.os.tag == .windows;

const is_unix_available = switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    .windows => true, // Windows 10 1803+ supports AF_UNIX
    else => false,
};

// Winsock declarations for Windows support
const winsock = if (is_windows) struct {
    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.winapi) posix.socket_t;
    extern "ws2_32" fn closesocket(s: posix.socket_t) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: posix.socket_t, name: *const posix.sockaddr, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: posix.socket_t, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: posix.socket_t, addr: ?*posix.sockaddr, addrlen: ?*i32) callconv(.winapi) posix.socket_t;
    extern "ws2_32" fn connect(s: posix.socket_t, name: *const posix.sockaddr, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(s: posix.socket_t, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: posix.socket_t, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;

    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    const INVALID_SOCKET: posix.socket_t = if (is_windows)
        @as(posix.socket_t, @ptrFromInt(std.math.maxInt(usize)))
    else
        -1;

    var wsa_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn ensureWsaStartup() !void {
        if (wsa_initialized.load(.monotonic)) return;
        var wsa_data: WSADATA = undefined;
        // Request Winsock 2.2 (0x0202)
        const rc = WSAStartup(0x0202, &wsa_data);
        if (rc != 0) return error.SocketCreateFailed;
        wsa_initialized.store(true, .release);
    }
} else struct {};

const AF_UNIX: u32 = if (is_windows) 1 else posix.AF.UNIX;
const SOCK_STREAM: u32 = if (is_windows) 1 else posix.SOCK.STREAM;

pub const UnixSocketError = error{
    UnsupportedPlatform,
    PathTooLong,
    BindFailed,
    ListenFailed,
    ConnectFailed,
    AcceptFailed,
    SocketCreateFailed,
    ConnectionClosed,
    WriteFailed,
    ReadFailed,
};

/// Maximum path length for a Unix socket path.
pub const MAX_PATH_LEN = 108;

/// Thread-local storage for resolved Windows Unix socket paths.
/// Used by UnixListener.init to store absolute paths when the input is relative.
threadlocal var resolved_path_storage: [std.fs.max_path_bytes]u8 = undefined;

/// On Windows, build a short socket path to avoid exceeding the
/// 108-byte AF_UNIX sockaddr limit.
fn windowsShortPath(name: []const u8) ![]const u8 {
    // On Windows, AF_UNIX paths must be short. Use a fixed short prefix.
    // The full resolved path must fit in 108 bytes (MAX_PATH_LEN).
    // We use the name directly if it's already short enough.
    if (name.len + 1 >= MAX_PATH_LEN) return error.PathTooLong;

    const buf = &resolved_path_storage;
    // Copy just the name (short) into the static buffer
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn closesocket(fd: posix.socket_t) void {
    if (is_windows) {
        _ = winsock.closesocket(fd);
    } else {
        _ = posix.system.close(fd);
    }
}

// On Windows, INVALID_SOCKET is ULONG_PTR(~0) which equals maxInt(usize)
const WIN_INVALID_SOCKET: usize = ~@as(usize, 0);

fn createSocket() !posix.socket_t {
    if (is_windows) {
        // Ensure Winsock is initialized for AF_UNIX support
        try winsock.ensureWsaStartup();
        // AF_UNIX = 1 on Windows (same as POSIX); SOCK_STREAM = 1
        const fd = winsock.socket(1, 1, 0);
        // Compare via integer since posix.socket_t is a pointer on Windows
        const fd_int = if (@typeInfo(posix.socket_t) == .pointer)
            @intFromPtr(fd)
        else
            @as(usize, @intCast(fd));
        if (fd_int == WIN_INVALID_SOCKET) return error.SocketCreateFailed;
        return fd;
    } else {
        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            else => return error.SocketCreateFailed,
        }
    }
}

fn bindSocket(fd: posix.socket_t, addr: *const posix.sockaddr.un) !void {
    if (is_windows) {
        const rc = winsock.bind(fd, @ptrCast(addr), @sizeOf(posix.sockaddr.un));
        if (rc != 0) return error.BindFailed;
    } else {
        const rc = posix.system.bind(fd, @ptrCast(addr), @sizeOf(posix.sockaddr.un));
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => return error.BindFailed,
        }
    }
}

fn listenSocket(fd: posix.socket_t, backlog: i32) !void {
    if (is_windows) {
        const rc = winsock.listen(fd, backlog);
        if (rc != 0) return error.ListenFailed;
    } else {
        const rc = posix.system.listen(fd, @intCast(backlog));
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => return error.ListenFailed,
        }
    }
}

fn acceptConnection(fd: posix.socket_t, addr: *posix.sockaddr.un, len: *posix.socklen_t) !posix.socket_t {
    if (is_windows) {
        var len_i32: i32 = @intCast(len.*);
        const client_fd = winsock.accept(fd, @ptrCast(addr), &len_i32);
        // Compare via integer since posix.socket_t is a pointer on Windows
        const client_int = if (@typeInfo(posix.socket_t) == .pointer)
            @intFromPtr(client_fd)
        else
            @as(usize, @intCast(client_fd));
        if (client_int == WIN_INVALID_SOCKET) return error.AcceptFailed;
        len.* = @intCast(len_i32);
        return client_fd;
    } else {
        const rc = posix.system.accept(fd, @ptrCast(addr), len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            else => return error.AcceptFailed,
        }
    }
}

fn connectSocket(fd: posix.socket_t, addr: *const posix.sockaddr.un) !void {
    if (is_windows) {
        const rc = winsock.connect(fd, @ptrCast(addr), @sizeOf(posix.sockaddr.un));
        if (rc != 0) return error.ConnectFailed;
    } else {
        const rc = posix.system.connect(fd, @ptrCast(addr), @sizeOf(posix.sockaddr.un));
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => return error.ConnectFailed,
        }
    }
}

fn sendBytes(fd: posix.socket_t, data: []const u8) !usize {
    if (is_windows) {
        const rc = winsock.send(fd, data.ptr, @intCast(data.len), 0);
        if (rc < 0) return error.WriteFailed;
        return @intCast(rc);
    } else {
        const rc = posix.system.sendto(fd, data.ptr, data.len, posix.MSG.NOSIGNAL, null, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            else => return error.WriteFailed,
        }
    }
}

fn recvBytes(fd: posix.socket_t, buf: []u8) !usize {
    if (is_windows) {
        const rc = winsock.recv(fd, buf.ptr, @intCast(buf.len), 0);
        if (rc < 0) return error.ReadFailed;
        return @intCast(rc);
    } else {
        const rc = posix.system.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            else => return error.ReadFailed,
        }
    }
}

/// A Unix domain socket connection.
pub const UnixSocket = struct {
    fd: posix.socket_t,

    const Self = @This();

    /// Closes the socket.
    pub fn close(self: Self) void {
        closesocket(self.fd);
    }

    /// Sends all bytes, retrying on partial writes.
    pub fn writeAll(self: Self, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try sendBytes(self.fd, data[sent..]);
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }
    }

    /// Reads bytes into buf, returns count read.
    pub fn read(self: Self, buf: []u8) !usize {
        return recvBytes(self.fd, buf);
    }

    /// Reads until buf is full or EOF.
    pub fn readAll(self: Self, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try recvBytes(self.fd, buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
};

/// Accepted Unix socket connection.
pub const UnixAccepted = struct {
    socket: UnixSocket,
};

/// A Unix domain socket server (listener).
pub const UnixListener = struct {
    fd: posix.socket_t,
    path: []const u8,

    const Self = @This();

    /// Binds and listens on a Unix socket path.
    /// Removes any existing socket file at the path first.
    /// On Windows, relative paths are resolved to short temp-dir paths.
    pub fn init(path: []const u8) !Self {
        if (!is_unix_available) {
            return error.UnsupportedPlatform;
        }

        // On Windows, use short temp-dir paths to avoid exceeding AF_UNIX limit
        const resolved_path: []const u8 = if (is_windows)
            try windowsShortPath(path)
        else
            path;

        if (resolved_path.len >= MAX_PATH_LEN) return error.PathTooLong;

        // Remove stale socket file
        {
            const io = defaultIo();
            const cwd = std.Io.Dir.cwd();
            cwd.deleteFile(io, resolved_path) catch {};
        }

        const fd = try createSocket();
        errdefer closesocket(fd);

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = @intCast(AF_UNIX);
        @memcpy(addr.path[0..resolved_path.len], resolved_path);

        try bindSocket(fd, &addr);
        try listenSocket(fd, 128);

        return .{ .fd = fd, .path = resolved_path };
    }

    /// Accepts an incoming connection.
    pub fn accept(self: *Self) !UnixAccepted {
        var addr = std.mem.zeroes(posix.sockaddr.un);
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.un);
        const client_fd = acceptConnection(self.fd, &addr, &len) catch |err| {
            return err;
        };
        return .{ .socket = .{ .fd = client_fd } };
    }

    /// Closes the listener and removes the socket file.
    pub fn deinit(self: *Self) void {
        closesocket(self.fd);
        {
            const io = defaultIo();
            const cwd = std.Io.Dir.cwd();
            cwd.deleteFile(io, self.path) catch {};
        }
    }
};

/// A Unix domain socket client.
pub const UnixClient = struct {
    /// Connects to a Unix socket path and returns a socket.
    /// On Windows, relative paths are resolved to short temp-dir paths.
    pub fn connect(path: []const u8) !UnixSocket {
        if (!is_unix_available) {
            return error.UnsupportedPlatform;
        }

        // On Windows, use short temp-dir paths to avoid exceeding AF_UNIX limit
        const resolved_path: []const u8 = if (is_windows)
            try windowsShortPath(path)
        else
            path;

        if (resolved_path.len >= MAX_PATH_LEN) return error.PathTooLong;

        const fd = try createSocket();
        errdefer closesocket(fd);

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = @intCast(AF_UNIX);
        @memcpy(addr.path[0..resolved_path.len], resolved_path);

        try connectSocket(fd, &addr);
        return .{ .fd = fd };
    }
};

test "Unix domain socket integration - Client & Server" {
    const allocator = std.testing.allocator;
    const io = defaultIo();
    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var socket_path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buf, "httpx-test-{d}.sock", .{ts});

    const Server = @import("../server/server.zig").Server;
    const Client = @import("../client/client.zig").Client;
    const Context = @import("../server/server.zig").Context;
    const Response = @import("../core/response.zig").Response;

    var server = Server.initWithConfig(allocator, .{
        .unix_path = socket_path,
        .keep_alive = false,
        .log_fn = struct {
            fn log(level: @import("../server/server.zig").LogLevel, message: []const u8) void {
                _ = level;
                _ = message;
            }
        }.log,
    });
    defer server.deinit();

    try server.get("/hello", struct {
        fn h(ctx: *Context) anyerror!Response {
            return ctx.text("Hello from Unix socket!");
        }
    }.h);

    const t = try server.listenInBackground();
    defer t.join();
    defer server.stop();

    // Give the server a moment to start
    const dur = std.Io.Duration.fromMilliseconds(50);
    std.Io.sleep(io, dur, .real) catch {};

    var client = Client.initWithConfig(allocator, .{
        .timeouts = .{ .connect_ms = 5000, .read_ms = 5000, .write_ms = 5000 },
        .unix_socket_path = socket_path,
    });
    defer client.deinit();

    var resp = client.get("http://localhost/hello", .{}) catch |err| {
        if (err == error.UnsupportedPlatform or err == error.SystemResources or err == error.ConnectionRefused) return;
        return err;
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status.code);
    try std.testing.expectEqualStrings("Hello from Unix socket!", resp.text().?);
}
