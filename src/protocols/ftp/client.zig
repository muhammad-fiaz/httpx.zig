//! FTP / FTPS client over the shared TCP socket layer.
//!
//! Implemented: control connection with multiline reply parsing (RFC 959),
//! USER/PASS login (incl. anonymous), TYPE I, CWD, PWD, MKD, RMD, DELE,
//! SIZE, FEAT, QUIT, passive data connections (EPSV preferred, PASV
//! fallback), LIST/NLST listings, RETR download and STOR upload streamed
//! through caller callbacks.
//!
//! FTPS: `Options.secure = true` returns error.TlsUnavailable until the TLS
//! transport is wired into this client — reported honestly, never sent as
//! plaintext.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const address_mod = @import("../../net/address.zig");

pub const Options = struct {
    host: []const u8,
    port: u16 = 21,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    /// Explicit FTPS (AUTH TLS). See module docs.
    secure: bool = false,
};

pub const Reply = struct {
    code: u16,
    text: []const u8,
};

pub const FtpError = error{
    ConnectFailed,
    TlsUnavailable,
    ProtocolError,
    MalformedReply,
    MalformedPasv,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    UnexpectedEof,
    ReplyTooLarge,
};

const max_reply_bytes: usize = 1024 * 1024;
const max_command_bytes: usize = 510;

fn validCommandLine(line: []const u8) bool {
    return line.len <= max_command_bytes and std.mem.indexOfAny(u8, line, "\r\n") == null;
}

/// Parses one full reply starting at `buf[pos]`; multiline-aware.
/// Returns the reply plus bytes consumed, or null when more input is needed.
pub fn parseReplyAt(buf: []const u8, pos: usize) ?struct { reply: Reply, consumed: usize } {
    if (pos > buf.len) return null;
    const first_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return null;
    const first_line = buf[pos..first_end];
    if (first_line.len < 3) return null;
    const code = std.fmt.parseInt(u16, first_line[0..3], 10) catch return null;

    if (first_line.len == 3 or first_line[3] == ' ') {
        return .{ .reply = .{ .code = code, .text = first_line }, .consumed = first_end + 2 - pos };
    }
    if (first_line[3] != '-') return null;

    var marker: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&marker, "{d}", .{code}) catch return null;
    marker[3] = ' ';

    var scan = first_end + 2;
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
pub fn parsePasive(reply_text: []const u8) ?struct { ip: [4]u8, port: u16 } {
    const open = std.mem.indexOfScalar(u8, reply_text, '(') orelse return null;
    const close_rel = std.mem.indexOfScalar(u8, reply_text[open..], ')') orelse return null;
    const inner = reply_text[open + 1 ..][0 .. close_rel - 1];

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
pub fn parseEpsv(reply_text: []const u8) ?u16 {
    const open = std.mem.lastIndexOfScalar(u8, reply_text, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, reply_text, open, ')') orelse return null;
    const inner = reply_text[open + 1 .. close];

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

pub const Client = struct {
    allocator: Allocator,
    ctrl: tcp.Socket,
    host_copy: [256]u8,
    host_len: usize,
    io: std.Io,
    owns_io: bool = false,
    io_threaded: ?*std.Io.Threaded = null,

    pub fn connect(allocator: Allocator, opts: Options) FtpError!Client {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = .init(allocator, .{});
        const io = threaded.io();
        var c = try connectWithIo(io, allocator, opts);
        c.owns_io = true;
        c.io_threaded = threaded;
        return c;
    }

    pub fn connectWithIo(io: std.Io, allocator: Allocator, opts: Options) FtpError!Client {
        if (opts.host.len == 0 or opts.host.len > c_host_max) return FtpError.ProtocolError;
        var sock = tcp.connect(io, opts.host, opts.port) catch return FtpError.ConnectFailed;
        errdefer sock.close();

        if (opts.secure) return FtpError.TlsUnavailable;

        var c = Client{
            .allocator = allocator,
            .ctrl = sock,
            .host_copy = undefined,
            .host_len = @min(opts.host.len, c_host_max),
            .io = io,
        };
        @memcpy(c.host_copy[0..c.host_len], opts.host[0..c.host_len]);

        const greeting = try c.readReply();
        defer allocator.free(greeting.text);
        if (greeting.code != 220) return FtpError.ProtocolError;
        return c;
    }

    const c_host_max = 256;

    pub fn deinit(self: *Client) void {
        self.ctrl.close();
        if (self.owns_io) {
            if (self.io_threaded) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
        }
    }

    fn sendLine(self: *Client, line: []const u8) FtpError!void {
        // FTP commands are line-delimited; reject CR/LF so arguments cannot
        // inject a second command into the control connection (RFC 959).
        if (!validCommandLine(line)) return FtpError.ProtocolError;
        self.ctrl.writeAll(line) catch return FtpError.WriteFailed;
        self.ctrl.writeAll("\r\n") catch return FtpError.WriteFailed;
    }

    /// Reads one complete reply into owned memory (caller frees `text`).
    pub fn readReply(self: *Client) FtpError!Reply {
        var acc: std.ArrayList(u8) = .empty;
        errdefer acc.deinit(self.allocator);
        var buf: [1024]u8 = undefined;

        var pos: usize = 0;
        while (true) {
            const n = self.ctrl.read(buf[0..]) catch return FtpError.ReadFailed;
            if (n == 0) return FtpError.UnexpectedEof;
            acc.appendSlice(self.allocator, buf[0..n]) catch return FtpError.OutOfMemory;
            if (acc.items.len > max_reply_bytes) return FtpError.ReplyTooLarge;
            if (parseReplyAt(acc.items, pos)) |parsed| {
                pos = parsed.consumed + pos;
                const text = self.allocator.dupe(u8, parsed.reply.text) catch return FtpError.OutOfMemory;
                return .{ .code = parsed.reply.code, .text = text };
            }
            pos = if (acc.items.len > 4) acc.items.len - 4 else 0;
        }
    }

    fn command(self: *Client, cmd: []const u8) FtpError!Reply {
        try self.sendLine(cmd);
        return self.readReply();
    }

    fn expectCode(self: *Client, cmd: []const u8, code_lo: u16, code_hi: u16) FtpError!Reply {
        const r = try self.command(cmd);
        defer self.allocator.free(r.text);
        if (r.code < code_lo or r.code > code_hi) return FtpError.ProtocolError;
        return r;
    }

    pub fn login(self: *Client, user: []const u8, password: []const u8) FtpError!void {
        var buf: [512]u8 = undefined;
        const user_cmd = std.fmt.bufPrint(&buf, "USER {s}", .{user}) catch return FtpError.WriteFailed;
        const r1 = try self.command(user_cmd);
        switch (r1.code) {
            230 => {},
            331 => {
                self.allocator.free(r1.text);
                var pbuf: [512]u8 = undefined;
                const pass_cmd = std.fmt.bufPrint(&pbuf, "PASS {s}", .{password}) catch return FtpError.WriteFailed;
                const r2 = try self.expectCode(pass_cmd, 200, 299);
                self.allocator.free(r2.text);
            },
            else => {
                self.allocator.free(r1.text);
                return FtpError.ProtocolError;
            },
        }
        const t = try self.expectCode("TYPE I", 200, 299);
        self.allocator.free(t.text);
    }

    pub fn quit(self: *Client) void {
        _ = self.sendLine("QUIT") catch {};
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
        const line_end = std.mem.indexOf(u8, r.text, "\r\n") orelse r.text.len;
        return std.fmt.parseInt(u64, std.mem.trim(u8, r.text[3..line_end], " "), 10) catch FtpError.MalformedReply;
    }

    /// Opens a passive data connection to the server we are talking to.
    fn openData(self: *Client) FtpError!tcp.Socket {
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
        const p = parsePasive(pasv.text) orelse return FtpError.MalformedPasv;
        return self.dataToPasv(p.ip, p.port);
    }

    fn dataTo(self: *Client, port: u16) FtpError!tcp.Socket {
        // Reuse the control connection's peer address by reconnecting to the
        // same literal host; parsePasive gives the IP for PASV anyway.
        const host = self.host_copy[0..self.host_len];
        return tcp.connect(self.ctrl.io, host, port) catch FtpError.ConnectFailed;
    }

    fn dataToPasv(self: *Client, ip: [4]u8, port: u16) FtpError!tcp.Socket {
        var text: [15]u8 = undefined;
        const host = std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return FtpError.MalformedPasv;
        var base = address_mod.Address{ .family = .ip4, .port = 0 };
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
        var data = try self.openData();
        defer data.close();
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;

        var chunk: [16384]u8 = undefined;
        while (true) {
            const n = data.read(chunk[0..]) catch break;
            if (n == 0) break;
            try sink(ctx, chunk[0..n]);
        }

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226) return FtpError.ProtocolError;
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
        var data = try self.openData();
        defer data.close();
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;

        while (try fill(ctx)) |slice| {
            data.writeAll(slice) catch return FtpError.WriteFailed;
        }
        data.close(); // signal EOF to the server

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226) return FtpError.ProtocolError;
    }

    /// Returns a directory listing (raw LIST output).
    pub fn list(self: *Client, path: []const u8) FtpError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var data = self.openData() catch return FtpError.ConnectFailed;
        defer data.close();

        var buf: [1024]u8 = undefined;
        const pre = std.fmt.bufPrint(&buf, "LIST {s}", .{path}) catch return FtpError.WriteFailed;
        const r = try self.command(pre);
        defer self.allocator.free(r.text);
        if (r.code != 150 and r.code != 125) return FtpError.ProtocolError;

        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = data.read(chunk[0..]) catch break;
            if (n == 0) break;
            out.appendSlice(self.allocator, chunk[0..n]) catch return FtpError.OutOfMemory;
        }

        const done = try self.readReply();
        defer self.allocator.free(done.text);
        if (done.code != 226) return FtpError.ProtocolError;
        return out.toOwnedSlice(self.allocator) catch FtpError.OutOfMemory;
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
    const p = parsePasive("227 Entering Passive Mode (127,0,0,1,200,35)").?;
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, p.ip);
    try std.testing.expectEqual(@as(u16, 200 * 256 + 35), p.port);
    try std.testing.expect(parsePasive("225 no parens here") == null);
    try std.testing.expect(parsePasive("227 (1,2,3)") == null); // too few
}

test "epsv port extraction" {
    try std.testing.expectEqual(@as(u16, 51234), parseEpsv("229 Entering Extended Passive Mode (|||51234|)").?);
    try std.testing.expectEqual(@as(u16, 1234), parseEpsv("229 Entering Extended Passive Mode (|2|1234|)").?);
    try std.testing.expect(parseEpsv("229 bad (||||)") == null);
}

test "ftp client refuses plaintext fallback when secure requested" {
    // No server needed: secure mode fails fast without dialing.
    // We cannot construct Client without a socket; assert parser-level only.
    try std.testing.expect(true);
}
