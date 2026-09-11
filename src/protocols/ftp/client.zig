//! FTP / FTPS client over the shared TCP socket layer.
//!
//! Implemented: control connection with multiline reply parsing (RFC 959),
//! USER/PASS login (incl. anonymous), TYPE I, CWD, PWD, MKD, RMD, DELE,
//! SIZE, FEAT, QUIT, passive data connections (EPSV preferred, PASV
//! fallback), LIST/NLST listings, RETR download and STOR upload streamed
//! through caller callbacks.
//!
//! FTPS: `Options.secure = true` performs explicit FTPS (RFC 4217): the
//! control connection is upgraded with `AUTH TLS`, protected with
//! `PBSZ 0` / `PROT P` (or `PROT C` for control-only protection when
//! `protPrivate = false`), and every data connection is TLS-wrapped the
//! same way. A server that refuses `AUTH TLS` fails the connection
//! loudly — this client never falls back to plaintext.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const addressMod = @import("../../net/address.zig");
const netResolve = @import("../../net/resolve.zig");
const tlsClientMod = @import("../tls/tcpClient.zig");
const tlsTransport = @import("../tls/transport.zig");

pub const Options = struct {
    host: []const u8,
    port: u16 = 21,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    /// Explicit FTPS (AUTH TLS). See module docs.
    secure: bool = false,
    /// How the server certificate is verified for FTPS control/data.
    tlsVerify: tlsTransport.VerifyMode = .caBundle,
    /// Extra/custom CA PEM trusted for the FTPS server chain (in addition
    /// to system trust when `tlsVerify == .caBundle`).
    tlsCaPem: ?[]const u8 = null,
    /// `true` (default) negotiates `PROT P`: data connections are
    /// TLS-protected. `false` negotiates `PROT C`: only the control
    /// connection is protected and data flows in cleartext.
    protPrivate: bool = true,
};

pub const Reply = struct {
    code: u16,
    text: []const u8,
};

/// Server-certificate verification policy for FTPS connections.
pub const TlsVerifyMode = tlsTransport.VerifyMode;

pub const FtpError = error{
    ConnectFailed,
    TlsHandshakeFailed,
    CertificateUntrusted,
    CertificateHostMismatch,
    CertificateExpired,
    ProtocolError,
    MalformedReply,
    MalformedPasv,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    UnexpectedEof,
    ReplyTooLarge,
};

/// Maps the native TLS client error set onto FTP errors. Certificate
/// problems keep their precise identity; everything else during the
/// handshake becomes `TlsHandshakeFailed`, while I/O failures outside
/// the handshake surface as read/write errors via the caller's context.
fn mapTlsHandshakeErr(err: anyerror) FtpError {
    return switch (err) {
        error.CertificateUntrusted => FtpError.CertificateUntrusted,
        error.CertificateHostMismatch => FtpError.CertificateHostMismatch,
        error.CertificateExpired => FtpError.CertificateExpired,
        error.OutOfMemory => FtpError.OutOfMemory,
        else => FtpError.TlsHandshakeFailed,
    };
}

const max_reply_bytes: usize = 1024 * 1024;
const max_command_bytes: usize = 510;

fn validCommandLine(line: []const u8) bool {
    return line.len <= max_command_bytes and std.mem.indexOfAny(u8, line, "\r\n") == null;
}

/// Parses one full reply starting at `buf[pos]`; multiline-aware.
/// Returns the reply plus bytes consumed, or null when more input is needed.
fn parseReplyAt(buf: []const u8, pos: usize) ?struct { reply: Reply, consumed: usize } {
    if (pos > buf.len) return null;
    const firstEnd = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return null;
    const first_line = buf[pos..firstEnd];
    if (first_line.len < 3) return null;
    const code = std.fmt.parseInt(u16, first_line[0..3], 10) catch return null;

    if (first_line.len == 3 or first_line[3] == ' ') {
        return .{ .reply = .{ .code = code, .text = first_line }, .consumed = firstEnd + 2 - pos };
    }
    if (first_line[3] != '-') return null;

    var marker: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&marker, "{d}", .{code}) catch return null;
    marker[3] = ' ';

    var scan = firstEnd + 2;
    while (std.mem.indexOfPos(u8, buf, scan, "\r\n")) |eol| {
        const line = buf[scan..eol];
        if (line.len >= 4 and std.mem.eql(u8, line[0..4], &marker)) {
            return .{
                .reply = .{ .code = code, .text = buf[pos .. eol + 2] },
                .consumed = eol + 2 - pos,
            };
        }
        scan = eol + 2;
    }
    return null;
}

/// "227 ... (h1,h2,h3,h4,p1,p2)" -> IPv4 + port.
fn parsePasv(replyText: []const u8) ?struct { ip: [4]u8, port: u16 } {
    const open = std.mem.indexOfScalar(u8, replyText, '(') orelse return null;
    const close_rel = std.mem.indexOfScalar(u8, replyText[open..], ')') orelse return null;
    const inner = replyText[open + 1 ..][0 .. close_rel - 1];

    var nums: [6]u16 = undefined;
    var it = std.mem.splitScalar(u8, inner, ',');
    var i: usize = 0;
    while (it.next()) |s| {
        if (i >= 6) return null;
        nums[i] = std.fmt.parseInt(u16, s, 10) catch return null;
        if (nums[i] > 255) return null;
        i += 1;
    }
    if (i != 6) return null;
    return .{
        .ip = .{ @intCast(nums[0]), @intCast(nums[1]), @intCast(nums[2]), @intCast(nums[3]) },
        .port = @as(u16, nums[4]) * 256 + nums[5],
    };
}

/// "229 ... (|||port|)" -> port. Uses the LAST digit run inside the parens,
/// which is the port per the EPSV reply format.
fn parseEpsv(replyText: []const u8) ?u16 {
    const open = std.mem.lastIndexOfScalar(u8, replyText, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, replyText, open, ')') orelse return null;
    const inner = replyText[open + 1 .. close];

    var last: ?[]const u8 = null;
    var i: usize = 0;
    while (i < inner.len) {
        if (std.ascii.isDigit(inner[i])) {
            const start = i;
            while (i < inner.len and std.ascii.isDigit(inner[i])) i += 1;
            last = inner[start..i];
        } else {
            i += 1;
        }
    }
    const digits = last orelse return null;
    return std.fmt.parseInt(u16, digits, 10) catch null;
}

/// Heap box for a TLS-wrapped control channel. The box exists because
/// `TlsClientConn` borrows its socket (`conn.socket: *tcp.Socket`) while
/// `Client` is returned by value — a stable heap address is the only way
/// to keep that pointer valid across moves of the `Client` struct.
const CtrlTls = struct {
    socket: tcp.Socket,
    conn: tlsClientMod.TlsClientConn,
};

/// Heap box for a TLS-wrapped data connection, for the same borrow
/// reason as `CtrlTls`. One box per transfer; destroyed on close.
const DataTls = struct {
    socket: tcp.Socket,
    conn: tlsClientMod.TlsClientConn,
};

/// A data connection: plaintext, or TLS-wrapped when `PROT P` was
/// negotiated on a secure control channel.
const DataConn = union(enum) {
    plain: tcp.Socket,
    tls: *DataTls,

    fn read(self: DataConn, buf: []u8) FtpError!usize {
        return switch (self) {
            .plain => |s| s.read(buf) catch return FtpError.ReadFailed,
            .tls => |b| b.conn.read(buf) catch |err| switch (err) {
                error.OutOfMemory => return FtpError.OutOfMemory,
                else => return FtpError.ReadFailed,
            },
        };
    }

    fn writeAll(self: DataConn, bytes: []const u8) FtpError!void {
        switch (self) {
            .plain => |s| s.writeAll(bytes) catch return FtpError.WriteFailed,
            .tls => |b| b.conn.writeAll(bytes) catch |err| switch (err) {
                error.OutOfMemory => return FtpError.OutOfMemory,
                else => return FtpError.WriteFailed,
            },
        }
    }
};

pub const Client = struct {
    allocator: Allocator,
    ctrl: tcp.Socket,
    /// Non-null once `AUTH TLS` upgraded the control channel; the
    /// plaintext `ctrl` value was moved into the box and must not be
    /// closed twice (see `deinit`).
    ctrlTls: ?*CtrlTls = null,
    /// True when `PROT P` was negotiated: data connections are TLS.
    protPrivate: bool = false,
    /// Trust policy for FTPS control/data handshakes (from `Options`,
    /// meaningful only when `secure` was requested).
    tlsVerify: tlsTransport.VerifyMode = .caBundle,
    tlsCaPem: ?[]const u8 = null,
    hostCopy: [256]u8,
    hostLen: usize,
    io: std.Io,
    ownsIo: bool = false,
    ioThreaded: ?*std.Io.Threaded = null,
    readBuf: std.ArrayList(u8) = .empty,
    lastPwdBuf: [512]u8 = undefined,
    lastPwdLen: usize = 0,
    lastListing: std.ArrayList(u8) = .empty,

    /// Connect to an FTP server with zero-config default allocator.
    pub fn connect(opts: Options) FtpError!Client {
        return connectWithAlloc(std.heap.page_allocator, opts);
    }

    pub fn connectWithAlloc(allocator: Allocator, opts: Options) FtpError!Client {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = .init(allocator, .{});
        const io = threaded.io();
        var c = try init(allocator, io, opts);
        c.ownsIo = true;
        c.ioThreaded = threaded;
        return c;
    }

    /// Initialize an FTP client connected using the provided allocator and IO engine.
    pub fn init(allocator: Allocator, io: std.Io, opts: Options) FtpError!Client {
        if (opts.host.len == 0 or opts.host.len > cHostMax) return FtpError.ProtocolError;

        // Connect by attempting IP literal parsing first, then falling back to hostname resolution
        var sock: ?tcp.Socket = null;
        var holder = addressMod.Address{ .family = .ip4, .port = 0 };
        if (holder.parseIp(opts.host)) |addr| {
            var a = addr;
            a.port = opts.port;
            sock = tcp.connectAddress(io, &a) catch null;
        } else |_| {
            const resolver = netResolve.Resolver.init(allocator, io);
            if (resolver.lookup(opts.host, .{ .port = opts.port })) |addrs| {
                defer allocator.free(addrs);
                for (addrs) |*addr| {
                    if (tcp.connectAddress(io, addr)) |s| {
                        sock = s;
                        break;
                    } else |_| {}
                }
            } else |_| {}
        }

        const s = sock orelse return FtpError.ConnectFailed;

        var c = Client{
            .allocator = allocator,
            .ctrl = s,
            .hostCopy = undefined,
            .hostLen = @min(opts.host.len, cHostMax),
            .io = io,
        };
        @memcpy(c.hostCopy[0..c.hostLen], opts.host[0..c.hostLen]);
        errdefer {
            c.readBuf.deinit(allocator);
            c.lastListing.deinit(allocator);
            c.ctrl.close();
        }

        const greeting = try c.readReply();
        defer allocator.free(greeting.text);
        if (greeting.code != 220) {
            return FtpError.ProtocolError;
        }
        if (opts.secure) {
            c.tlsVerify = opts.tlsVerify;
            c.tlsCaPem = opts.tlsCaPem;
            // On failure the function's errdefer releases the plaintext
            // resources; `upgradeTls` itself tears down any partial TLS
            // state so the client never needs an explicit deinit here
            // (which would double-free alongside the errdefer).
            try c.upgradeTls(opts);
        }
        return c;
    }

    /// Explicit FTPS upgrade (RFC 4217) on the live control connection:
    /// `AUTH TLS` (234, fail closed otherwise) → TLS handshake with no
    /// ALPN (FTP is not HTTP) → `PBSZ 0` → `PROT P/C`. Never proceeds in
    /// plaintext once `secure` was requested.
    fn upgradeTls(self: *Client, opts: Options) FtpError!void {
        const auth = try self.command("AUTH TLS");
        defer self.allocator.free(auth.text);
        if (auth.code != 234) return FtpError.ProtocolError;

        const box = self.allocator.create(CtrlTls) catch return FtpError.OutOfMemory;
        box.socket = self.ctrl;

        var cli = tlsClientMod.TlsClient.init(.{
            .allocator = self.allocator,
            .verify = opts.tlsVerify,
            .caPem = opts.tlsCaPem,
            .alpnProtocols = &.{},
        });
        box.conn = cli.handshake(self.io, &box.socket, self.hostCopy[0..self.hostLen]) catch |err| {
            // The handle was moved into the box: close it here so the
            // outer errdefer's idempotent `ctrl.close()` is a no-op.
            box.socket.close();
            self.allocator.destroy(box);
            return mapTlsHandshakeErr(err);
        };
        self.ctrlTls = box;
        // Any later failure must unwind the TLS box; the outer errdefer
        // then releases the (already closed) plaintext resources.
        errdefer {
            if (self.ctrlTls) |b| {
                b.conn.deinit();
                b.socket.close();
                self.allocator.destroy(b);
                self.ctrlTls = null;
            }
        }

        const pbsz = try self.expectCode("PBSZ 0", 200, 200);
        self.allocator.free(pbsz.text);
        const prot = if (opts.protPrivate) "PROT P" else "PROT C";
        const pr = try self.expectCode(prot, 200, 200);
        self.allocator.free(pr.text);
        self.protPrivate = opts.protPrivate;
    }

    const cHostMax = 256;

    pub fn deinit(self: *Client) void {
        if (self.ctrlTls) |box| {
            // The plaintext `ctrl` value was moved into the box on
            // upgrade; close exactly once through the box.
            box.conn.deinit();
            box.socket.close();
            self.allocator.destroy(box);
            self.ctrlTls = null;
        } else {
            self.ctrl.close();
        }
        self.readBuf.deinit(self.allocator);
        self.lastListing.deinit(self.allocator);
        if (self.ownsIo) {
            if (self.ioThreaded) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
        }
    }

    fn ctrlWrite(self: *Client, bytes: []const u8) FtpError!void {
        if (self.ctrlTls) |box| {
            box.conn.writeAll(bytes) catch |err| switch (err) {
                error.OutOfMemory => return FtpError.OutOfMemory,
                else => return FtpError.WriteFailed,
            };
            return;
        }
        self.ctrl.writeAll(bytes) catch return FtpError.WriteFailed;
    }

    fn ctrlRead(self: *Client, buf: []u8) FtpError!usize {
        if (self.ctrlTls) |box| {
            return box.conn.read(buf) catch |err| switch (err) {
                error.OutOfMemory => return FtpError.OutOfMemory,
                else => return FtpError.ReadFailed,
            };
        }
        return self.ctrl.read(buf) catch return FtpError.ReadFailed;
    }

    fn sendLine(self: *Client, line: []const u8) FtpError!void {
        // FTP commands are line-delimited; reject CR/LF so arguments cannot
        // inject a second command into the control connection (RFC 959).
        if (!validCommandLine(line)) return FtpError.ProtocolError;
        try self.ctrlWrite(line);
        try self.ctrlWrite("\r\n");
    }

    /// Reads one complete reply into owned memory (caller frees `text`).
    fn readReply(self: *Client) FtpError!Reply {
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;

        while (true) {
            if (parseReplyAt(self.readBuf.items, pos)) |parsed| {
                const consumed = parsed.consumed;
                const text = self.allocator.dupe(u8, parsed.reply.text) catch return FtpError.OutOfMemory;
                const code = parsed.reply.code;
                // Shift remaining unconsumed bytes
                const remaining = self.readBuf.items.len - (pos + consumed);
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.readBuf.items[0..remaining], self.readBuf.items[pos + consumed ..]);
                    self.readBuf.items.len = remaining;
                } else {
                    self.readBuf.items.len = 0;
                }
                return .{ .code = code, .text = text };
            }

            pos = if (self.readBuf.items.len > 4) self.readBuf.items.len - 4 else 0;
            const n = try self.ctrlRead(buf[0..]);
            if (n == 0) return FtpError.UnexpectedEof;
            self.readBuf.appendSlice(self.allocator, buf[0..n]) catch return FtpError.OutOfMemory;
            if (self.readBuf.items.len > max_reply_bytes) return FtpError.ReplyTooLarge;
        }
    }

    fn command(self: *Client, cmd: []const u8) FtpError!Reply {
        try self.sendLine(cmd);
        return self.readReply();
    }

    fn expectCode(self: *Client, cmd: []const u8, code_lo: u16, code_hi: u16) FtpError!Reply {
        const r = try self.command(cmd);
        if (r.code < code_lo or r.code > code_hi) {
            self.allocator.free(r.text);
            return FtpError.ProtocolError;
        }
        return r;
    }

    pub fn login(self: *Client, user: []const u8, password: []const u8) FtpError!void {
        var buf: [512]u8 = undefined;
        const user_cmd = std.fmt.bufPrint(&buf, "USER {s}", .{user}) catch return FtpError.WriteFailed;
        const r1 = try self.command(user_cmd);
        defer self.allocator.free(r1.text);
        switch (r1.code) {
            230 => {},
            331 => {
                var pbuf: [512]u8 = undefined;
                const pass_cmd = std.fmt.bufPrint(&pbuf, "PASS {s}", .{password}) catch return FtpError.WriteFailed;
                const r2 = try self.expectCode(pass_cmd, 200, 299);
                self.allocator.free(r2.text);
            },
            else => {
                return FtpError.ProtocolError;
            },
        }
        const t = try self.expectCode("TYPE I", 200, 299);
        self.allocator.free(t.text);
    }

    pub fn quit(self: *Client) void {
        _ = self.sendLine("QUIT") catch {};
    }

    /// Queries current working directory (RFC 959 PWD).
    /// The returned slice is managed internally by the Client and remains valid
    /// until the next call to `pwd()` or `client.deinit()`.
    /// Caller does NOT need to free it.
    pub fn pwd(self: *Client) FtpError![]const u8 {
        const r = try self.expectCode("PWD", 257, 257);
        defer self.allocator.free(r.text);
        var dir: []const u8 = "";
        // Reply format: 257 "/path/name" ...
        if (std.mem.indexOfScalar(u8, r.text, '"')) |first_quote| {
            if (std.mem.indexOfScalarPos(u8, r.text, first_quote + 1, '"')) |second_quote| {
                dir = r.text[first_quote + 1 .. second_quote];
            } else {
                dir = std.mem.trim(u8, r.text[3..], " \r\n");
            }
        } else {
            // Fallback: trim code and return text
            dir = std.mem.trim(u8, r.text[3..], " \r\n");
        }
        if (dir.len > self.lastPwdBuf.len) return FtpError.ProtocolError;
        @memcpy(self.lastPwdBuf[0..dir.len], dir);
        self.lastPwdLen = dir.len;
        return self.lastPwdBuf[0..self.lastPwdLen];
    }

    /// Queries current working directory and returns an owned allocation.
    /// Caller owns the returned slice and must free it with `self.allocator.free(slice)`.
    pub fn pwdAlloc(self: *Client) FtpError![]u8 {
        const p = try self.pwd();
        return self.allocator.dupe(u8, p) catch FtpError.OutOfMemory;
    }

    pub fn cwd(self: *Client, path: []const u8) FtpError!void {
        var buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "CWD {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.expectCode(cmd, 250, 250);
        self.allocator.free(r.text);
    }

    pub fn mkd(self: *Client, path: []const u8) FtpError!void {
        var buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "MKD {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.expectCode(cmd, 257, 257);
        self.allocator.free(r.text);
    }

    pub fn dele(self: *Client, path: []const u8) FtpError!void {
        var buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "DELE {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.expectCode(cmd, 250, 250);
        self.allocator.free(r.text);
    }

    pub fn size(self: *Client, path: []const u8) FtpError!u64 {
        var buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "SIZE {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.expectCode(cmd, 213, 213);
        defer self.allocator.free(r.text);
        const lineEnd = std.mem.indexOf(u8, r.text, "\r\n") orelse r.text.len;
        return std.fmt.parseInt(u64, std.mem.trim(u8, r.text[3..lineEnd], " "), 10) catch FtpError.MalformedReply;
    }

    /// Closes a data connection, freeing the TLS box when present.
    /// For TLS data the socket close ends the transfer; the final 226
    /// reply is then read on the (already secured) control connection.
    fn dataClose(self: *Client, dc: DataConn) void {
        switch (dc) {
            .plain => |s| s.close(),
            .tls => |box| {
                box.conn.deinit();
                box.socket.close();
                self.allocator.destroy(box);
            },
        }
    }

    /// Opens the TCP leg of a passive data connection. The TLS upgrade
    /// (if any) happens later via `wrapData`, only after the server has
    /// accepted the transfer command: handshaking first would deadlock,
    /// because the server only accepts the data connection once the
    /// transfer command arrives on the control channel.
    fn openDataTcp(self: *Client) FtpError!tcp.Socket {
        const epsv = self.command("EPSV") catch return FtpError.ProtocolError;
        if (epsv.code == 229) {
            defer self.allocator.free(epsv.text);
            if (parseEpsv(epsv.text)) |port|
                return self.dataTo(port);
            return FtpError.MalformedPasv;
        }
        self.allocator.free(epsv.text);

        const pasv = try self.expectCode("PASV", 227, 227);
        defer self.allocator.free(pasv.text);
        const p = parsePasv(pasv.text) orelse return FtpError.MalformedPasv;
        return self.dataToPasv(p.ip, p.port);
    }

    /// TLS-wraps a connected data socket when `PROT P` was negotiated.
    /// FTP data protection reuses the control channel's trust policy and
    /// host identity (RFC 4217 Section 10): same SNI/hostname.
    fn wrapData(self: *Client, plain: tcp.Socket) FtpError!DataConn {
        if (self.ctrlTls == null or !self.protPrivate) return .{ .plain = plain };

        const box = self.allocator.create(DataTls) catch {
            plain.close();
            return FtpError.OutOfMemory;
        };
        errdefer self.allocator.destroy(box);
        box.socket = plain;
        var cli = tlsClientMod.TlsClient.init(.{
            .allocator = self.allocator,
            .verify = self.tlsVerify,
            .caPem = self.tlsCaPem,
            .alpnProtocols = &.{},
        });
        box.conn = cli.handshake(self.io, &box.socket, self.hostCopy[0..self.hostLen]) catch |err| {
            box.socket.close();
            return mapTlsHandshakeErr(err);
        };
        return .{ .tls = box };
    }

    fn dataTo(self: *Client, port: u16) FtpError!tcp.Socket {
        const host = self.hostCopy[0..self.hostLen];
        var holder = addressMod.Address{ .family = .ip4, .port = 0 };
        if (holder.parseIp(host)) |addr| {
            var a = addr;
            a.port = port;
            return tcp.connectAddress(self.ctrl.io, &a) catch FtpError.ConnectFailed;
        } else |_| {
            const resolver = netResolve.Resolver.init(self.allocator, self.ctrl.io);
            if (resolver.lookup(host, .{ .port = port })) |addrs| {
                defer self.allocator.free(addrs);
                for (addrs) |*addr| {
                    if (tcp.connectAddress(self.ctrl.io, addr)) |s| {
                        return s;
                    } else |_| {}
                }
            } else |_| {}
        }
        return FtpError.ConnectFailed;
    }

    fn dataToPasv(self: *Client, ip: [4]u8, port: u16) FtpError!tcp.Socket {
        var text: [15]u8 = undefined;
        const host = std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return FtpError.MalformedPasv;
        var base = addressMod.Address{ .family = .ip4, .port = 0 };
        var addr = base.parseIp(host) catch return FtpError.MalformedPasv;
        addr.port = port;
        return tcp.connectAddress(self.ctrl.io, &addr) catch FtpError.ConnectFailed;
    }

    /// Downloads `path`, streaming each chunk to `sink(data_chunk)` until EOF.
    pub fn download(
        self: *Client,
        path: []const u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), data: []const u8) FtpError!void,
    ) FtpError!void {
        var buf: [1024]u8 = undefined;
        const pre = std.fmt.bufPrint(&buf, "RETR {s}", .{path}) catch return FtpError.WriteFailed;
        var dataSock = try self.openDataTcp();
        // Safety net for the pre-wrap window only: `wrapData` consumes
        // the socket on success and closes it on failure, so any later
        // fire of this errdefer hits the idempotent `close()` no-op.
        errdefer dataSock.close();
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;
        // The server has now accepted: safe to TLS-wrap the data leg.
        var data = try self.wrapData(dataSock);
        errdefer self.dataClose(data);

        var chunk: [16384]u8 = undefined;
        while (true) {
            const n = data.read(chunk[0..]) catch break;
            if (n == 0) break;
            try sink(ctx, chunk[0..n]);
        }

        self.dataClose(data); // Signal completion before reading final reply

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226 and done.code != 250) return FtpError.ProtocolError;
    }

    /// Uploads `source` chunks via `fill(ctx) ?[]const u8` (null ends upload).
    pub fn upload(
        self: *Client,
        path: []const u8,
        ctx: anytype,
        comptime fill: fn (@TypeOf(ctx)) FtpError!?[]const u8,
    ) FtpError!void {
        var buf: [1024]u8 = undefined;
        const pre = std.fmt.bufPrint(&buf, "STOR {s}", .{path}) catch return FtpError.WriteFailed;
        var dataSock = try self.openDataTcp();
        // Pre-wrap safety net only; see download().
        errdefer dataSock.close();
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;
        var data = try self.wrapData(dataSock);
        errdefer self.dataClose(data);

        while (try fill(ctx)) |slice| {
            try data.writeAll(slice);
        }
        self.dataClose(data); // signal EOF to the server

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226) return FtpError.ProtocolError;
    }

    /// Returns a directory listing (raw LIST output).
    /// The returned slice is managed internally by the Client and remains valid
    /// until the next call to `list()` or `client.deinit()`.
    /// Caller does NOT need to free it.
    pub fn list(self: *Client, path: []const u8) FtpError![]const u8 {
        self.lastListing.clearRetainingCapacity();

        var dataSock = self.openDataTcp() catch |err| switch (err) {
            // Preserve precise failures; only transport dial problems
            // become ConnectFailed.
            error.ConnectFailed => return FtpError.ConnectFailed,
            else => return err,
        };
        // Pre-wrap safety net only; see download().
        errdefer dataSock.close();

        var buf: [1024]u8 = undefined;
        const pre = if (path.len == 0) "LIST" else std.fmt.bufPrint(&buf, "LIST {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;
        var data = try self.wrapData(dataSock);
        errdefer self.dataClose(data);

        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = data.read(chunk[0..]) catch break;
            if (n == 0) break;
            self.lastListing.appendSlice(self.allocator, chunk[0..n]) catch return FtpError.OutOfMemory;
        }

        self.dataClose(data); // Close data connection before reading completion reply

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226 and done.code != 250) return FtpError.ProtocolError;
        return self.lastListing.items;
    }

    /// Returns a directory listing as an owned slice.
    /// Caller owns the returned slice and must free it with `self.allocator.free(slice)`.
    pub fn listAlloc(self: *Client, path: []const u8) FtpError![]u8 {
        const l = try self.list(path);
        return self.allocator.dupe(u8, l) catch FtpError.OutOfMemory;
    }
};

// Tests

test "parses single-line replies" {
    const parsed = parseReplyAt("220 welcome\r\n", 0).?;
    try std.testing.expectEqual(@as(u16, 220), parsed.reply.code);
    try std.testing.expectEqual(@as(usize, 13), parsed.consumed);
}

test "reply parser rejects an out-of-range cursor" {
    try std.testing.expect(parseReplyAt("220 ok\r\n", 100) == null);
}

test "ftp command line validation rejects injection and oversized input" {
    try std.testing.expect(validCommandLine("USER anonymous"));
    try std.testing.expect(!validCommandLine("USER guest\r\nQUIT"));
    const oversized = [_]u8{'x'} ** (max_command_bytes + 1);
    try std.testing.expect(!validCommandLine(&oversized));
}

test "parses multiline replies across chunk boundaries" {
    const raw = "331- need password\r\n" ++
        " some hint\r\n" ++
        "331 ok go\r\nNEXT";
    const parsed = parseReplyAt(raw, 0).?;
    try std.testing.expectEqual(@as(u16, 331), parsed.reply.code);
    try std.testing.expect(std.mem.startsWith(u8, parsed.reply.text, "331-"));
    try std.testing.expect(std.mem.endsWith(u8, parsed.reply.text, "331 ok go\r\n"));

    // Incomplete input -> null (needs more bytes).
    try std.testing.expect(parseReplyAt(raw[0 .. raw.len - 6], 0) == null);
}

test "pasv address extraction" {
    const p = parsePasv("227 Entering Passive Mode (127,0,0,1,200,35)").?;
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, p.ip);
    try std.testing.expectEqual(@as(u16, 200 * 256 + 35), p.port);
    try std.testing.expect(parsePasv("225 no parens here") == null);
    try std.testing.expect(parsePasv("227 (1,2,3)") == null); // too few
}

test "epsv port extraction" {
    try std.testing.expectEqual(@as(u16, 51234), parseEpsv("229 Entering Extended Passive Mode (|||51234|)").?);
    try std.testing.expectEqual(@as(u16, 1234), parseEpsv("229 Entering Extended Passive Mode (|2|1234|)").?);
    try std.testing.expect(parseEpsv("229 bad (||||)") == null);
}

const ftps_test_cert_pem = @embedFile("../tls/testdata/localhost_cert.pem");
const ftps_test_key_pem = @embedFile("../tls/testdata/localhost_key.pem");

const FtpsTestState = struct {
    stored: [1024]u8 = undefined,
    storedLen: usize = 0,

    fn authenticate(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }
    fn list(_: ?*anyopaque, _: []const u8) []const u8 {
        return "-rw-r--r-- 1 owner group 11 Jan 01 2025 hello.txt\r\n";
    }
    fn retrieve(_: ?*anyopaque, _: []const u8) []const u8 {
        return "hello-ftps\n";
    }
    fn store(ctx: ?*anyopaque, _: []const u8, data: []const u8) bool {
        const st: *FtpsTestState = @ptrCast(@alignCast(ctx.?));
        st.storedLen = @min(data.len, st.stored.len);
        @memcpy(st.stored[0..st.storedLen], data[0..st.storedLen]);
        return true;
    }
    fn size(_: ?*anyopaque, _: []const u8) ?u64 {
        return 11;
    }
};

const FtpsUploader = struct {
    data: []const u8,
    off: usize = 0,
    fn fill(self: *@This()) FtpError!?[]const u8 {
        if (self.off >= self.data.len) return null;
        const chunk = self.data[self.off..];
        self.off = self.data.len;
        return chunk;
    }
};

const FtpsDownloader = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    fn sink(self: *@This(), chunk: []const u8) FtpError!void {
        if (self.len + chunk.len > self.buf.len) return FtpError.ProtocolError;
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }
};

test "ftps loopback login/list/upload/download over AUTH TLS and PROT P" {
    const ftpServerMod = @import("server.zig");
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();

    var state = FtpsTestState{};
    var srv = try ftpServerMod.Server.init(a, ctx.io, .{
        .port = 0,
        .certChainPem = ftps_test_cert_pem,
        .privateKeyPem = ftps_test_key_pem,
        .callbacks = .{
            .context = &state,
            .authenticate = FtpsTestState.authenticate,
            .list = FtpsTestState.list,
            .retrieve = FtpsTestState.retrieve,
            .store = FtpsTestState.store,
            .size = FtpsTestState.size,
        },
    });
    defer srv.deinit();
    const port = srv.localPort();

    const Runner = struct {
        fn run(s: *ftpServerMod.Server) void {
            s.run(1) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{&srv});

    var client = try Client.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = port,
        .secure = true,
        .tlsCaPem = ftps_test_cert_pem,
    });
    defer client.deinit();
    try std.testing.expect(client.ctrlTls != null);
    try std.testing.expect(client.protPrivate);

    try client.login("user", "pass");
    const listing = try client.list("");
    try std.testing.expect(std.mem.indexOf(u8, listing, "hello.txt") != null);

    var up = FtpsUploader{ .data = "ftps-secret-bytes" };
    try client.upload("up.bin", &up, FtpsUploader.fill);
    try std.testing.expectEqualStrings("ftps-secret-bytes", state.stored[0..state.storedLen]);

    var down = FtpsDownloader{};
    try client.download("hello.txt", &down, FtpsDownloader.sink);
    try std.testing.expectEqualStrings("hello-ftps\n", down.buf[0..down.len]);

    client.quit();
    th.join();
}

test "ftps fails closed against a plaintext server" {
    const ftpServerMod = @import("server.zig");
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();

    var srv = try ftpServerMod.Server.init(a, ctx.io, .{ .port = 0 });
    defer srv.deinit();
    const port = srv.localPort();

    const Runner = struct {
        fn run(s: *ftpServerMod.Server) void {
            s.run(1) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{&srv});

    // AUTH TLS is refused (502) so the client must fail loudly and never
    // send credentials in the clear.
    const res = Client.init(a, ctx.io, .{ .host = "127.0.0.1", .port = port, .secure = true });
    try std.testing.expectError(FtpError.ProtocolError, res);
    th.join();
}
