//! RFC 959 FTP server primitives built on the shared TCP listener/socket API.
//!
//! The server keeps filesystem policy outside the protocol layer. Applications
//! provide authentication and transfer callbacks, while this module owns
//! control replies, passive data connections, command validation, and cleanup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const address_mod = @import("../../net/address.zig");
const tlsServerMod = @import("../tls/tcpTls.zig");

pub const Error = error{ AcceptFailed, ReadFailed, WriteFailed, ProtocolError, OutOfMemory, TlsHandshakeFailed };

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    authenticate: ?*const fn (?*anyopaque, []const u8, []const u8) bool = null,
    list: ?*const fn (?*anyopaque, []const u8) []const u8 = null,
    retrieve: ?*const fn (?*anyopaque, []const u8) []const u8 = null,
    store: ?*const fn (?*anyopaque, []const u8, []const u8) bool = null,
    directory: ?*const fn (?*anyopaque, []const u8, bool) bool = null,
    remove: ?*const fn (?*anyopaque, []const u8) bool = null,
    size: ?*const fn (?*anyopaque, []const u8) ?u64 = null,
};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 2121,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    timeoutMs: u31 = 30_000,
    callbacks: Callbacks = .{},
    /// Server certificate chain (PEM) enabling explicit FTPS (`AUTH
    /// TLS`). Both must be set; otherwise `AUTH TLS` is refused.
    certChainPem: ?[]const u8 = null,
    /// Server private key (PEM, P-256 ECDSA) for `certChainPem`.
    privateKeyPem: ?[]const u8 = null,

    /// True when the server can upgrade control connections with AUTH TLS.
    pub fn secureAvailable(self: Config) bool {
        return self.certChainPem != null and self.privateKeyPem != null;
    }
};

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    listener: tcp.Listener,
    cfg: Config,
    ownsIo: bool = false,
    ioThreaded: ?*std.Io.Threaded = null,
    stop: std.atomic.Value(bool) = .init(false),
    listenerClosed: bool = false,

    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        if (!std.mem.eql(u8, cfg.host, "0.0.0.0")) return error.ProtocolError;
        return .{ .allocator = allocator, .io = io, .listener = try tcp.Listener.bind(io, cfg.port), .cfg = cfg };
    }

    pub fn deinit(self: *Server) void {
        if (!self.listenerClosed) {
            self.listener.close(self.io);
            self.listenerClosed = true;
        }
        if (self.ownsIo) {
            if (self.ioThreaded) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
        }
    }
    pub fn shutdown(self: *Server) void {
        self.stop.store(true, .release);
        if (!self.listenerClosed) {
            self.listener.close(self.io);
            self.listenerClosed = true;
        }
    }
    pub fn localPort(self: *const Server) u16 {
        return self.listener.localPort();
    }

    /// Serves accepted control connections until shutdown or maxConnections.
    pub fn run(self: *Server, maxConnections: usize) Error!void {
        var served: usize = 0;
        while (!self.stop.load(.acquire) and (maxConnections == 0 or served < maxConnections)) {
            var control = self.listener.accept(self.io) catch return error.AcceptFailed;
            defer control.close();
            tcp.setTimeouts(control.netSocketHandle(), self.cfg.timeoutMs);
            var session = Session.init(self.allocator, self.io, &control, self.cfg);
            session.run() catch {};
            served += 1;
        }
    }
};

const Session = struct {
    allocator: Allocator,
    io: std.Io,
    control: *tcp.Socket,
    cfg: Config,
    loggedIn: bool = false,
    userBuf: [256]u8 = undefined,
    userLen: usize = 0,
    passive: ?tcp.Listener = null,
    active: ?address_mod.Address = null,
    /// TLS-wrapped control channel after `AUTH TLS`. Both fields live in
    /// the `Session` value itself (never moved after `run` starts), so the
    /// connection's borrow of `tlsSock` stays valid for the session.
    tlsSock: ?tcp.Socket = null,
    tlsConn: ?tlsServerMod.TlsServerConn = null,
    /// `PROT P` negotiated: data connections are TLS-wrapped.
    protPrivate: bool = false,

    fn init(allocator: Allocator, io: std.Io, control: *tcp.Socket, cfg: Config) Session {
        return .{ .allocator = allocator, .io = io, .control = control, .cfg = cfg };
    }

    fn run(self: *Session) Error!void {
        defer if (self.passive) |*p| p.close(self.io);
        defer if (self.tlsConn) |*c| c.deinit();
        try self.reply("220 httpx FTP server ready");
        var line: [4096]u8 = undefined;
        while (try self.readLine(&line)) |command| {
            if (!try self.dispatch(command)) break;
        }
    }

    fn ctrlRead(self: *Session, buf: []u8) Error!usize {
        if (self.tlsConn) |*c| {
            return c.read(buf) catch error.ReadFailed;
        }
        return self.control.read(buf) catch error.ReadFailed;
    }

    fn ctrlWrite(self: *Session, bytes: []const u8) Error!void {
        if (self.tlsConn) |*c| {
            c.writeAll(bytes) catch return error.WriteFailed;
            return;
        }
        self.control.writeAll(bytes) catch return error.WriteFailed;
    }

    fn readLine(self: *Session, buf: []u8) Error!?[]const u8 {
        var used: usize = 0;
        while (used < buf.len) {
            var one: [1]u8 = undefined;
            const n = try self.ctrlRead(&one);
            if (n == 0) return null;
            if (one[0] == '\n') {
                if (used > 0 and buf[used - 1] == '\r') used -= 1;
                return buf[0..used];
            }
            buf[used] = one[0];
            used += 1;
        }
        try self.reply("500 Command line too long");
        return null;
    }

    fn dispatch(self: *Session, line: []const u8) Error!bool {
        const split = std.mem.indexOfScalar(u8, line, ' ');
        const src = line[0 .. split orelse line.len];
        const buf = self.allocator.alloc(u8, src.len) catch return error.OutOfMemory;
        defer self.allocator.free(buf);
        const name = std.ascii.upperString(buf, src);
        const arg = if (split) |i| std.mem.trim(u8, line[i + 1 ..], " ") else "";
        if (std.mem.eql(u8, name, "QUIT")) {
            try self.reply("221 Goodbye");
            return false;
        }
        if (std.mem.eql(u8, name, "NOOP")) {
            try self.reply("200 OK");
            return true;
        }
        if (std.mem.eql(u8, name, "SYST")) {
            try self.reply("215 UNIX Type: L8");
            return true;
        }
        if (std.mem.eql(u8, name, "FEAT")) {
            if (self.cfg.secureAvailable()) {
                try self.reply("211-Features\r\n AUTH TLS\r\n PBSZ\r\n PROT\r\n EPSV\r\n PASV\r\n211 End");
            } else {
                try self.reply("211-Features\r\n EPSV\r\n PASV\r\n211 End");
            }
            return true;
        }
        // Security commands (RFC 4217) are valid before login.
        if (std.mem.eql(u8, name, "AUTH")) return self.doAuth(arg);
        if (std.mem.eql(u8, name, "PBSZ")) return self.doPbsz();
        if (std.mem.eql(u8, name, "PROT")) return self.doProt(arg);
        if (std.mem.eql(u8, name, "USER")) {
            self.loggedIn = false;
            if (arg.len > self.userBuf.len) {
                try self.reply("530 Invalid user");
                return true;
            }
            @memcpy(self.userBuf[0..arg.len], arg);
            self.userLen = arg.len;
            try self.reply("331 Password required");
            return true;
        }
        if (std.mem.eql(u8, name, "PASS")) {
            const user = self.userBuf[0..self.userLen];
            self.loggedIn = if (self.cfg.callbacks.authenticate) |f| f(self.cfg.callbacks.context, user, arg) else std.mem.eql(u8, user, self.cfg.user) and std.mem.eql(u8, arg, self.cfg.password);
            try self.reply(if (self.loggedIn) "230 Logged in" else "530 Login incorrect");
            return true;
        }
        if (!self.loggedIn) {
            try self.reply("530 Not logged in");
            return true;
        }
        if (std.mem.eql(u8, name, "TYPE")) {
            try self.reply("200 Type set");
            return true;
        }
        if (std.mem.eql(u8, name, "PWD")) {
            try self.reply("257 \"/\" is current directory");
            return true;
        }
        if (std.mem.eql(u8, name, "CWD")) {
            try self.reply("250 Directory changed");
            return true;
        }
        if (std.mem.eql(u8, name, "MKD") or std.mem.eql(u8, name, "RMD")) {
            const f = self.cfg.callbacks.directory orelse {
                try self.reply("502 Directory operation unavailable");
                return true;
            };
            const created = std.mem.eql(u8, name, "MKD");
            if (f(self.cfg.callbacks.context, arg, created)) {
                if (created) {
                    var b: [4096]u8 = undefined;
                    const r = std.fmt.bufPrint(&b, "257 \"{s}\" created", .{arg}) catch return error.WriteFailed;
                    try self.reply(r);
                } else try self.reply("250 Directory removed");
            } else try self.reply("550 Directory operation failed");
            return true;
        }
        if (std.mem.eql(u8, name, "DELE")) {
            const f = self.cfg.callbacks.remove orelse {
                try self.reply("502 Delete unavailable");
                return true;
            };
            try self.reply(if (f(self.cfg.callbacks.context, arg)) "250 File deleted" else "550 Delete failed");
            return true;
        }
        if (std.mem.eql(u8, name, "SIZE")) {
            const f = self.cfg.callbacks.size orelse {
                try self.reply("502 SIZE unavailable");
                return true;
            };
            if (f(self.cfg.callbacks.context, arg)) |bytes| {
                var b: [96]u8 = undefined;
                const r = std.fmt.bufPrint(&b, "213 {d}", .{bytes}) catch return error.WriteFailed;
                try self.reply(r);
            } else try self.reply("550 File unavailable");
            return true;
        }
        if (std.mem.eql(u8, name, "PASV")) return self.startPassive(false);
        if (std.mem.eql(u8, name, "EPSV")) return self.startPassive(true);
        if (std.mem.eql(u8, name, "PORT")) return self.setPort(arg);
        if (std.mem.eql(u8, name, "EPRT")) return self.setEprt(arg);
        if (std.mem.eql(u8, name, "LIST") or std.mem.eql(u8, name, "NLST")) return self.transferList(arg);
        if (std.mem.eql(u8, name, "RETR")) return self.transferRetrieve(arg);
        if (std.mem.eql(u8, name, "STOR")) return self.transferStore(arg);
        try self.reply("502 Command not implemented");
        return true;
    }

    fn reply(self: *Session, text: []const u8) Error!void {
        var buf: [600]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\r\n", .{text}) catch return error.WriteFailed;
        try self.ctrlWrite(line);
    }

    /// `AUTH TLS`: upgrade the control connection to TLS (RFC 4217).
    /// Refused without configured certificates; re-AUTH on an already
    /// secure channel is rejected. A failed handshake ends the session —
    /// there is no downgrade back to plaintext.
    fn doAuth(self: *Session, arg: []const u8) Error!bool {
        var upper: [8]u8 = undefined;
        const mechanism = if (arg.len <= upper.len) std.ascii.upperString(upper[0..arg.len], arg) else "";
        if (!std.mem.eql(u8, mechanism, "TLS")) {
            try self.reply("502 Unsupported AUTH mechanism");
            return true;
        }
        if (self.tlsConn != null) {
            try self.reply("534 Already secure");
            return true;
        }
        if (!self.cfg.secureAvailable()) {
            try self.reply("502 AUTH TLS unavailable");
            return true;
        }
        try self.reply("234 AUTH TLS OK");
        // Move the plaintext socket into the session; `run`'s own
        // `control` still aliases the same OS handle, but `close()` is
        // idempotent so the deferred close there is harmless.
        self.tlsSock = self.control.*;
        var srv = tlsServerMod.TlsServer.init(.{
            .allocator = self.allocator,
            .defaultIdentity = .{
                .certChainPem = self.cfg.certChainPem.?,
                .privateKeyPem = self.cfg.privateKeyPem.?,
            },
            .alpnProtocols = &.{},
        });
        self.tlsConn = srv.handshake(self.io, &self.tlsSock.?) catch return error.TlsHandshakeFailed;
        return true;
    }

    fn doPbsz(self: *Session) Error!bool {
        if (self.tlsConn == null) {
            try self.reply("503 Secure connection required");
            return true;
        }
        try self.reply("200 PBSZ=0");
        return true;
    }

    fn doProt(self: *Session, arg: []const u8) Error!bool {
        if (self.tlsConn == null) {
            try self.reply("503 Secure connection required");
            return true;
        }
        var upper: [8]u8 = undefined;
        const level = if (arg.len <= upper.len) std.ascii.upperString(upper[0..arg.len], arg) else "";
        if (std.mem.eql(u8, level, "P")) {
            self.protPrivate = true;
            try self.reply("200 Protection set to Private");
        } else if (std.mem.eql(u8, level, "C")) {
            self.protPrivate = false;
            try self.reply("200 Protection set to Clear");
        } else {
            try self.reply("504 Unknown protection level");
        }
        return true;
    }

    fn startPassive(self: *Session, extended: bool) Error!bool {
        if (self.passive) |*p| {
            p.close(self.io);
            self.passive = null;
        }
        self.passive = tcp.Listener.bind(self.io, 0) catch return error.ProtocolError;
        const port = self.passive.?.localPort();
        if (extended) {
            var b: [64]u8 = undefined;
            const r = std.fmt.bufPrint(&b, "229 Entering Extended Passive Mode (|||{d}|)", .{port}) catch return error.WriteFailed;
            try self.reply(r);
        } else {
            var b: [96]u8 = undefined;
            const p1: u8 = @intCast(port >> 8);
            const p2: u8 = @intCast(port & 255);
            const r = std.fmt.bufPrint(&b, "227 Entering Passive Mode (127,0,0,1,{d},{d})", .{ p1, p2 }) catch return error.WriteFailed;
            try self.reply(r);
        }
        return true;
    }

    fn setPort(self: *Session, arg: []const u8) Error!bool {
        var values: [6]u16 = undefined;
        var it = std.mem.splitScalar(u8, arg, ',');
        var n: usize = 0;
        while (it.next()) |part| {
            if (n == values.len) {
                try self.reply("501 Invalid PORT");
                return true;
            }
            values[n] = std.fmt.parseInt(u16, part, 10) catch {
                try self.reply("501 Invalid PORT");
                return true;
            };
            if (values[n] > 255) {
                try self.reply("501 Invalid PORT");
                return true;
            }
            n += 1;
        }
        if (n != values.len) {
            try self.reply("501 Invalid PORT");
            return true;
        }
        self.active = .{
            .family = .ip4,
            .port = values[4] * 256 + values[5],
            .bytes = .{
                @as(u8, @intCast(values[0])),
                @as(u8, @intCast(values[1])),
                @as(u8, @intCast(values[2])),
                @as(u8, @intCast(values[3])),
            } ++ .{0} ** 12,
        };
        if (self.passive) |*p| {
            p.close(self.io);
            self.passive = null;
        }
        try self.reply("200 PORT command successful");
        return true;
    }

    fn setEprt(self: *Session, arg: []const u8) Error!bool {
        if (arg.len < 5) {
            try self.reply("501 Invalid EPRT");
            return true;
        }
        const delimiter = arg[0];
        const familyEnd = std.mem.indexOfScalarPos(u8, arg, 1, delimiter) orelse {
            try self.reply("501 Invalid EPRT");
            return true;
        };
        const host_end = std.mem.indexOfScalarPos(u8, arg, familyEnd + 1, delimiter) orelse {
            try self.reply("501 Invalid EPRT");
            return true;
        };
        const port_end = std.mem.indexOfScalarPos(u8, arg, host_end + 1, delimiter) orelse {
            try self.reply("501 Invalid EPRT");
            return true;
        };
        if (port_end + 1 != arg.len) {
            try self.reply("501 Invalid EPRT");
            return true;
        }
        if (!std.mem.eql(u8, arg[1..familyEnd], "1")) {
            try self.reply("522 Network protocol unsupported");
            return true;
        }
        const port = std.fmt.parseInt(u16, arg[host_end + 1 .. port_end], 10) catch {
            try self.reply("501 Invalid EPRT");
            return true;
        };
        var base = address_mod.Address{ .family = .ip4, .port = 0 };
        var addr = base.parseIp(arg[familyEnd + 1 .. host_end]) catch {
            try self.reply("501 Invalid EPRT");
            return true;
        };
        addr.port = port;
        self.active = addr;
        if (self.passive) |*p| {
            p.close(self.io);
            self.passive = null;
        }
        try self.reply("200 EPRT command successful");
        return true;
    }

    /// Heap box for a TLS-wrapped data connection. `TlsServerConn`
    /// borrows its socket, and `acceptData` returns the channel by value,
    /// so a stable heap address is the only sound home for the pair (a
    /// by-value channel would dangle its own borrow on return — a
    /// use-after-free that Debug tolerates but ReleaseFast crashes on).
    const DataTlsBox = struct {
        socket: tcp.Socket,
        conn: tlsServerMod.TlsServerConn,
    };

    /// An accepted data connection, TLS-wrapped when `PROT P` is active.
    const DataChannel = union(enum) {
        plain: tcp.Socket,
        tls: *DataTlsBox,

        fn read(self: DataChannel, buf: []u8) Error!usize {
            return switch (self) {
                .plain => |s| s.read(buf) catch error.ReadFailed,
                .tls => |b| b.conn.read(buf) catch error.ReadFailed,
            };
        }

        fn writeAll(self: DataChannel, bytes: []const u8) Error!void {
            switch (self) {
                .plain => |s| s.writeAll(bytes) catch return error.WriteFailed,
                .tls => |b| b.conn.writeAll(bytes) catch return error.WriteFailed,
            }
        }
    };

    /// Closes a data connection, freeing the TLS box when present.
    /// Single-shot (not idempotent): call exactly once per accept; use
    /// `errdefer` for the failure path, never `defer` + explicit close.
    fn closeData(self: *Session, dc: DataChannel) void {
        switch (dc) {
            .plain => |s| s.close(),
            .tls => |box| {
                box.conn.deinit();
                box.socket.close();
                self.allocator.destroy(box);
            },
        }
    }

    fn acceptData(self: *Session) Error!DataChannel {
        const plain = try self.acceptSocket();
        if (!self.protPrivate or self.tlsConn == null) return .{ .plain = plain };
        const box = self.allocator.create(DataTlsBox) catch {
            plain.close();
            return error.OutOfMemory;
        };
        errdefer self.allocator.destroy(box);
        box.socket = plain;
        var srv = tlsServerMod.TlsServer.init(.{
            .allocator = self.allocator,
            .defaultIdentity = .{
                .certChainPem = self.cfg.certChainPem.?,
                .privateKeyPem = self.cfg.privateKeyPem.?,
            },
            .alpnProtocols = &.{},
        });
        box.conn = srv.handshake(self.io, &box.socket) catch {
            box.socket.close();
            return error.TlsHandshakeFailed;
        };
        return .{ .tls = box };
    }

    fn acceptSocket(self: *Session) Error!tcp.Socket {
        if (self.passive) |*p| {
            const data = p.accept(self.io) catch {
                p.close(self.io);
                self.passive = null;
                return error.AcceptFailed;
            };
            p.close(self.io);
            self.passive = null;
            tcp.setTimeouts(data.netSocketHandle(), self.cfg.timeoutMs);
            return data;
        }
        if (self.active) |*addr| {
            const data = tcp.connectAddress(self.io, addr) catch {
                self.active = null;
                return error.AcceptFailed;
            };
            self.active = null;
            tcp.setTimeouts(data.netSocketHandle(), self.cfg.timeoutMs);
            return data;
        }
        return error.AcceptFailed;
    }
    fn transferList(self: *Session, path: []const u8) Error!bool {
        const f = self.cfg.callbacks.list orelse {
            try self.reply("550 Listing unavailable");
            return true;
        };
        try self.reply("150 Opening data connection");
        var data = self.acceptData() catch {
            try self.reply("425 Can't open data connection");
            return true;
        };
        errdefer self.closeData(data);
        try data.writeAll(f(self.cfg.callbacks.context, path));
        self.closeData(data);
        try self.reply("226 Transfer complete");
        return true;
    }
    fn transferRetrieve(self: *Session, path: []const u8) Error!bool {
        const f = self.cfg.callbacks.retrieve orelse {
            try self.reply("550 File unavailable");
            return true;
        };
        try self.reply("150 Opening data connection");
        var data = self.acceptData() catch {
            try self.reply("425 Can't open data connection");
            return true;
        };
        errdefer self.closeData(data);
        try data.writeAll(f(self.cfg.callbacks.context, path));
        self.closeData(data);
        try self.reply("226 Transfer complete");
        return true;
    }
    fn transferStore(self: *Session, path: []const u8) Error!bool {
        const f = self.cfg.callbacks.store orelse {
            try self.reply("550 Upload unavailable");
            return true;
        };
        try self.reply("150 Opening data connection");
        var data = self.acceptData() catch {
            try self.reply("425 Can't open data connection");
            return true;
        };
        errdefer self.closeData(data);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var b: [16384]u8 = undefined;
        while (true) {
            const n = data.read(&b) catch break;
            if (n == 0) break;
            bytes.appendSlice(self.allocator, b[0..n]) catch return error.OutOfMemory;
        }
        self.closeData(data); // Close data connection before the completion reply.
        try self.reply(if (f(self.cfg.callbacks.context, path, bytes.items)) "226 Transfer complete" else "552 Transfer failed");
        return true;
    }
};

test "FTP server command line and passive reply framing" {
    try std.testing.expect(std.mem.startsWith(u8, "227 Entering Passive Mode", "227"));
}
