const std = @import("std");
const net = @import("../net/compat.zig");
const Socket = @import("../net/socket.zig").Socket;
const any_io = @import("../io/any_io.zig");
const address = @import("../net/address.zig");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

pub const TransferMode = enum {
    ascii,
    binary,

    pub fn toString(self: TransferMode) []const u8 {
        return switch (self) {
            .ascii => "A",
            .binary => "I",
        };
    }
};

pub const ConnectionMode = enum {
    active,
    passive,
};

pub const FtpConfig = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16 = 21,
    timeout_ms: u64 = 30_000,
    tls: ?TlsConfig = null,
    connection_mode: ConnectionMode = .passive,
    transfer_mode: TransferMode = .binary,

    pub const TlsConfig = struct {
        ca_bundle: ?[]const u8 = null,
        insecure: bool = false,
    };
};

pub const FtpError = error{
    ConnectionFailed,
    ConnectionTimeout,
    AuthenticationFailed,
    CommandFailed,
    DataConnectionFailed,
    TransferFailed,
    InvalidResponse,
    TlsNotSupported,
    UnsupportedFeature,
    Cancelled,
};

pub const Response = struct {
    code: u16,
    message: []const u8,
    owned_message: []const u8,
    multiline: bool,

    pub fn isSuccess(self: Response) bool {
        return self.code >= 200 and self.code < 300;
    }

    pub fn isPositive(self: Response) bool {
        return self.code < 400;
    }

    pub fn isNegative(self: Response) bool {
        return self.code >= 400;
    }

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.owned_message);
    }
};

pub const DirectoryEntry = struct {
    name: []const u8,
    is_directory: bool,
    is_symlink: bool = false,
    size: ?u64 = null,
    modified: ?[]const u8 = null,
    permissions: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

pub const Features = struct {
    epsv: bool = false,
    eprt: bool = false,
    size: bool = false,
    mdtm: bool = false,
    rest: bool = false,
    tvfs: bool = false,
    utf8: bool = false,
};

pub const FtpClient = struct {
    allocator: Allocator,
    control: Socket,
    config: FtpConfig,
    authenticated: bool = false,
    features: Features = .{},
    data_address: ?net.Address = null,
    read_buf: [4096]u8 = undefined,

    pub fn connect(allocator: Allocator, config: FtpConfig) !FtpClient {
        const addr = try address.resolve(allocator, config.host, config.port);

        var sock = try Socket.createForAddress(addr);
        errdefer sock.close();
        try sock.connect(addr);

        var client = FtpClient{
            .allocator = allocator,
            .control = sock,
            .config = config,
        };

        const greeting = try client.readResponseInternal();
        if (!greeting.isSuccess()) {
            greeting.deinit(allocator);
            return error.ConnectionFailed;
        }
        var mut_greeting = greeting;
        mut_greeting.deinit(allocator);

        _ = try client.sendCommand("FEAT");
        const feat_resp = try client.readResponseInternal();
        client.parseFeatures(&feat_resp);
        var mut_feat = feat_resp;
        mut_feat.deinit(allocator);

        return client;
    }

    pub fn deinit(self: *FtpClient) void {
        _ = self.sendCommand("QUIT") catch {};
        const quit_resp = self.readResponseInternal() catch return;
        var mut_resp = quit_resp;
        mut_resp.deinit(self.allocator);
        self.control.close();
    }

    pub fn login(self: *FtpClient, username: []const u8, password: []const u8) !Response {
        var cmd_buf: [512]u8 = undefined;
        const user_cmd = std.fmt.bufPrint(&cmd_buf, "USER {s}", .{username}) catch return error.CommandFailed;
        const user_resp = try self.sendCommandOwned(user_cmd);
        if (user_resp.code != 331 and !user_resp.isSuccess()) {
            return user_resp;
        }
        var mut_user = user_resp;
        mut_user.deinit(self.allocator);

        const pass_cmd = std.fmt.bufPrint(&cmd_buf, "PASS {s}", .{password}) catch return error.CommandFailed;
        const pass_resp = try self.sendCommandOwned(pass_cmd);
        if (pass_resp.isSuccess()) self.authenticated = true;
        return pass_resp;
    }

    pub fn anonymousLogin(self: *FtpClient) !Response {
        return self.login("anonymous", "anonymous@");
    }

    pub fn quit(self: *FtpClient) !Response {
        return self.sendCommand("QUIT");
    }

    pub fn pwd(self: *FtpClient) !Response {
        return self.sendCommand("PWD");
    }

    pub fn cwd(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "CWD {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn cdup(self: *FtpClient) !Response {
        return self.sendCommand("CDUP");
    }

    pub fn list(self: *FtpClient, path: ?[]const u8) ![]DirectoryEntry {
        var data_conn = try self.openDataConnection();
        errdefer data_conn.close();

        if (path) |p| {
            var cmd_buf: [1024]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "LIST {s}", .{p}) catch return error.CommandFailed;
            var cmd_resp = try self.sendCommandOwned(cmd);
            if (cmd_resp.isNegative()) {
                cmd_resp.deinit(self.allocator);
                return error.CommandFailed;
            }
            cmd_resp.deinit(self.allocator);
        } else {
            var cmd_resp = try self.sendCommand("LIST");
            if (cmd_resp.isNegative()) {
                cmd_resp.deinit(self.allocator);
                return error.CommandFailed;
            }
            cmd_resp.deinit(self.allocator);
        }

        var entries = std.ArrayList(DirectoryEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*entry| {
                self.allocator.free(entry.name);
                if (entry.permissions) |p| self.allocator.free(p);
                if (entry.owner) |o| self.allocator.free(o);
                if (entry.group) |g| self.allocator.free(g);
                if (entry.modified) |m| self.allocator.free(m);
            }
            entries.deinit();
        }

        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const n = data_conn.read(line_buf[line_len..]) catch break;
            if (n == 0) {
                if (line_len > 0) {
                    if (self.parseListEntry(line_buf[0..line_len])) |entry| {
                        var owned_entry = entry;
                        owned_entry.name = try self.allocator.dupe(u8, entry.name);
                        if (entry.permissions) |p| owned_entry.permissions = try self.allocator.dupe(u8, p);
                        if (entry.owner) |o| owned_entry.owner = try self.allocator.dupe(u8, o);
                        if (entry.group) |g| owned_entry.group = try self.allocator.dupe(u8, g);
                        if (entry.modified) |m| owned_entry.modified = try self.allocator.dupe(u8, m);
                        try entries.append(owned_entry);
                    }
                }
                break;
            }

            var start: usize = 0;
            for (line_buf[line_len .. line_len + n], 0..) |c, i| {
                if (c == '\n') {
                    const line = mem.trim(u8, line_buf[start .. line_len + i], "\r\n");
                    if (line.len > 0) {
                        if (self.parseListEntry(line)) |entry| {
                            var owned_entry = entry;
                            owned_entry.name = try self.allocator.dupe(u8, entry.name);
                            if (entry.permissions) |p| owned_entry.permissions = try self.allocator.dupe(u8, p);
                            if (entry.owner) |o| owned_entry.owner = try self.allocator.dupe(u8, o);
                            if (entry.group) |g| owned_entry.group = try self.allocator.dupe(u8, g);
                            if (entry.modified) |m| owned_entry.modified = try self.allocator.dupe(u8, m);
                            try entries.append(owned_entry);
                        }
                    }
                    start = line_len + i + 1;
                }
            }

            const remaining = line_len + n - start;
            if (remaining > 0 and start > 0) {
                mem.copyForwards(u8, line_buf[0..remaining], line_buf[start .. line_len + n]);
            }
            line_len = remaining;
        }

        data_conn.close();

        const data_resp = try self.readResponseInternal();
        var mut_data = data_resp;
        mut_data.deinit(self.allocator);

        return try entries.toOwnedSlice();
    }

    pub fn nlst(self: *FtpClient, path: ?[]const u8) ![]DirectoryEntry {
        var data_conn = try self.openDataConnection();
        errdefer data_conn.close();

        if (path) |p| {
            var cmd_buf: [1024]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "NLST {s}", .{p}) catch return error.CommandFailed;
            var cmd_resp = try self.sendCommandOwned(cmd);
            if (cmd_resp.isNegative()) {
                cmd_resp.deinit(self.allocator);
                return error.CommandFailed;
            }
            cmd_resp.deinit(self.allocator);
        } else {
            var cmd_resp = try self.sendCommand("NLST");
            if (cmd_resp.isNegative()) {
                cmd_resp.deinit(self.allocator);
                return error.CommandFailed;
            }
            cmd_resp.deinit(self.allocator);
        }

        var entries = std.ArrayList(DirectoryEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*entry| {
                self.allocator.free(entry.name);
            }
            entries.deinit();
        }

        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const n = data_conn.read(line_buf[line_len..]) catch break;
            if (n == 0) {
                if (line_len > 0) {
                    const line = mem.trim(u8, line_buf[0..line_len], "\r\n");
                    if (line.len > 0) {
                        try entries.append(.{
                            .name = try self.allocator.dupe(u8, line),
                            .is_directory = false,
                        });
                    }
                }
                break;
            }

            var start: usize = 0;
            for (line_buf[line_len .. line_len + n], 0..) |c, i| {
                if (c == '\n') {
                    const line = mem.trim(u8, line_buf[start .. line_len + i], "\r\n");
                    if (line.len > 0) {
                        try entries.append(.{
                            .name = try self.allocator.dupe(u8, line),
                            .is_directory = false,
                        });
                    }
                    start = line_len + i + 1;
                }
            }

            const remaining = line_len + n - start;
            if (remaining > 0 and start > 0) {
                mem.copyForwards(u8, line_buf[0..remaining], line_buf[start .. line_len + n]);
            }
            line_len = remaining;
        }

        data_conn.close();

        const data_resp = try self.readResponseInternal();
        var mut_data = data_resp;
        mut_data.deinit(self.allocator);

        return try entries.toOwnedSlice();
    }

    pub fn size(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "SIZE {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn mdtm(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "MDTM {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn retr(self: *FtpClient, path: []const u8, writer: anytype) !Response {
        var data_conn = try self.openDataConnection();
        errdefer data_conn.close();

        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "RETR {s}", .{path}) catch return error.CommandFailed;
        var cmd_resp = try self.sendCommandOwned(cmd);
        if (cmd_resp.isNegative()) {
            cmd_resp.deinit(self.allocator);
            data_conn.close();
            return error.CommandFailed;
        }
        cmd_resp.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = data_conn.read(&buf) catch break;
            if (n == 0) break;
            try writer.writeAll(buf[0..n]);
        }

        data_conn.close();

        const data_resp = try self.readResponseInternal();
        return data_resp;
    }

    pub fn stor(self: *FtpClient, path: []const u8, reader: anytype) !Response {
        var data_conn = try self.openDataConnection();
        errdefer data_conn.close();

        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "STOR {s}", .{path}) catch return error.CommandFailed;
        var cmd_resp = try self.sendCommandOwned(cmd);
        if (cmd_resp.isNegative()) {
            cmd_resp.deinit(self.allocator);
            data_conn.close();
            return error.CommandFailed;
        }
        cmd_resp.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;
            data_conn.writeAll(buf[0..n]) catch break;
        }

        data_conn.close();

        const data_resp = try self.readResponseInternal();
        return data_resp;
    }

    pub fn appe(self: *FtpClient, path: []const u8, reader: anytype) !Response {
        var data_conn = try self.openDataConnection();
        errdefer data_conn.close();

        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "APPE {s}", .{path}) catch return error.CommandFailed;
        var cmd_resp = try self.sendCommandOwned(cmd);
        if (cmd_resp.isNegative()) {
            cmd_resp.deinit(self.allocator);
            data_conn.close();
            return error.CommandFailed;
        }
        cmd_resp.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;
            data_conn.writeAll(buf[0..n]) catch break;
        }

        data_conn.close();

        const data_resp = try self.readResponseInternal();
        return data_resp;
    }

    pub fn dele(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "DELE {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn rnfr(self: *FtpClient, from: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "RNFR {s}", .{from}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn rnto(self: *FtpClient, to: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "RNTO {s}", .{to}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn mkd(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "MKD {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn rmd(self: *FtpClient, path: []const u8) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "RMD {s}", .{path}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn setType(self: *FtpClient, mode: TransferMode) !Response {
        var cmd_buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "TYPE {s}", .{mode.toString()}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn rest(self: *FtpClient, offset: u64) !Response {
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "REST {d}", .{offset}) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn noop(self: *FtpClient) !Response {
        return self.sendCommand("NOOP");
    }

    pub fn abor(self: *FtpClient) !Response {
        return self.sendCommand("ABOR");
    }

    pub fn pasv(self: *FtpClient) !Response {
        const resp = try self.sendCommand("PASV");
        if (resp.isSuccess()) {
            if (parsePasvAddress(resp.message)) |addr| {
                self.data_address = addr;
            }
        }
        return resp;
    }

    pub fn epsv(self: *FtpClient) !Response {
        const resp = try self.sendCommand("EPSV 1");
        if (resp.isSuccess()) {
            if (parseEpsvAddress(resp.message)) |addr| {
                self.data_address = addr;
            }
        }
        return resp;
    }

    pub fn port(self: *FtpClient, addr: net.Address) !Response {
        const ipv4 = addr.in;
        const bytes = @as(*const [4]u8, @ptrCast(&ipv4.sa.addr));
        const port_bytes = @as(*const [2]u8, @ptrCast(&ipv4.sa.port));
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "PORT {d},{d},{d},{d},{d},{d}",
            .{ bytes[0], bytes[1], bytes[2], bytes[3], port_bytes[0], port_bytes[1] },
        ) catch return error.CommandFailed;
        return self.sendCommandOwned(cmd);
    }

    pub fn eprt(self: *FtpClient, addr: net.Address) !Response {
        _ = addr;
        return self.sendCommand("EPRT |1|127.0.0.1|0|");
    }

    fn sendCommand(self: *FtpClient, cmd: []const u8) !Response {
        return self.sendCommandOwned(cmd);
    }

    fn sendCommandOwned(self: *FtpClient, cmd: []const u8) !Response {
        const writer = self.control.writer();
        writer.writeAll(cmd) catch return error.CommandFailed;
        writer.writeAll("\r\n") catch return error.CommandFailed;
        return self.readResponseInternal();
    }

    fn readResponseInternal(self: *FtpClient) !Response {
        const reader = self.control.reader();
        var buf: [4096]u8 = undefined;
        var total_len: usize = 0;

        while (total_len < buf.len) {
            const n = reader.read(buf[total_len..]) catch break;
            if (n == 0) break;
            total_len += n;

            if (total_len >= 4) {
                const code_str = buf[0..3];
                const code = std.fmt.parseInt(u16, code_str, 10) catch continue;

                if (buf[3] == ' ') {
                    const msg = mem.trimRight(u8, buf[4..total_len], "\r\n");
                    return Response{
                        .code = code,
                        .message = msg,
                        .owned_message = try self.allocator.dupe(u8, msg),
                        .multiline = false,
                    };
                }

                if (total_len >= 5 and buf[3] == '-' and buf[total_len - 4] == code_str[0] and buf[total_len - 3] == code_str[1] and buf[total_len - 2] == code_str[2] and buf[total_len - 1] == ' ') {
                    const msg_start: usize = 4;
                    const msg = mem.trimRight(u8, buf[msg_start .. total_len - 4], "\r\n");
                    return Response{
                        .code = code,
                        .message = msg,
                        .owned_message = try self.allocator.dupe(u8, msg),
                        .multiline = true,
                    };
                }
            }
        }

        return error.InvalidResponse;
    }

    fn openDataConnection(self: *FtpClient) !Socket {
        switch (self.config.connection_mode) {
            .passive => {
                if (self.features.epsv) {
                    var resp = try self.epsv();
                    if (resp.isNegative()) {
                        resp.deinit(self.allocator);
                        return error.DataConnectionFailed;
                    }
                    resp.deinit(self.allocator);
                } else {
                    var resp = try self.pasv();
                    if (resp.isNegative()) {
                        resp.deinit(self.allocator);
                        return error.DataConnectionFailed;
                    }
                    resp.deinit(self.allocator);
                }

                const addr = self.data_address orelse return error.DataConnectionFailed;
                var sock = try Socket.createForAddress(addr);
                errdefer sock.close();
                try sock.connect(addr);
                return sock;
            },
            .active => {
                return error.UnsupportedFeature;
            },
        }
    }

    fn parseFeatures(self: *FtpClient, resp: *const Response) void {
        if (mem.indexOf(u8, resp.message, "EPSV") != null) self.features.epsv = true;
        if (mem.indexOf(u8, resp.message, "EPRT") != null) self.features.eprt = true;
        if (mem.indexOf(u8, resp.message, "SIZE") != null) self.features.size = true;
        if (mem.indexOf(u8, resp.message, "MDTM") != null) self.features.mdtm = true;
        if (mem.indexOf(u8, resp.message, "REST") != null) self.features.rest = true;
        if (mem.indexOf(u8, resp.message, "TVFS") != null) self.features.tvfs = true;
        if (mem.indexOf(u8, resp.message, "UTF8") != null) self.features.utf8 = true;
    }

    fn parseListEntry(self: *FtpClient, line: []const u8) ?DirectoryEntry {
        _ = self;
        if (line.len < 10) return null;

        const is_dir = line[0] == 'd';
        const is_symlink = line[0] == 'l';

        var parts = mem.splitScalar(u8, line, ' ');
        var part_idx: usize = 0;
        var name_start: usize = 0;
        var name_end: usize = line.len;

        while (parts.next()) |part| {
            part_idx += 1;
            if (part_idx == 9) {
                name_start = @intFromPtr(part.ptr) - @intFromPtr(line.ptr);
            }
        }

        if (part_idx < 9) return null;

        const name_part = mem.trimRight(u8, line[name_start..name_end], "\r\n");
        if (name_part.len == 0) return null;

        if (is_symlink) {
            if (mem.indexOf(u8, name_part, " -> ")) |arrow_pos| {
                name_end = name_start + arrow_pos;
            }
        }

        const name = line[name_start..name_end];

        var entry_size: ?u64 = null;
        parts = mem.splitScalar(u8, line, ' ');
        part_idx = 0;
        while (parts.next()) |part| {
            part_idx += 1;
            if (part_idx == 5) {
                entry_size = std.fmt.parseInt(u64, part, 10) catch null;
                break;
            }
        }

        return DirectoryEntry{
            .name = name,
            .is_directory = is_dir,
            .is_symlink = is_symlink,
            .size = entry_size,
        };
    }
};

pub fn parsePasvAddress(response: []const u8) ?net.Address {
    const start = mem.indexOf(u8, response, "(") orelse return null;
    const end = mem.indexOf(u8, response, ")") orelse return null;
    const inner = response[start + 1 .. end];

    var parts = mem.splitScalar(u8, inner, ',');
    var nums: [6]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 6) return null;
        nums[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 6) return null;

    const port: u16 = @as(u16, nums[4]) * 256 + nums[5];
    const addr = net.Address.initIp4(.{ nums[0], nums[1], nums[2], nums[3] }, port);
    return addr;
}

pub fn parseEpsvAddress(response: []const u8) ?net.Address {
    const start = mem.indexOf(u8, response, "(|||") orelse return null;
    const end = mem.indexOf(u8, response, "|)") orelse return null;
    const port_str = response[start + 4 .. end];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    return net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
}

test "Response isSuccess" {
    const resp = Response{ .code = 200, .message = "OK", .owned_message = "OK", .multiline = false };
    try testing.expect(resp.isSuccess());
    try testing.expect(resp.isPositive());
    try testing.expect(!resp.isNegative());
}

test "Response isNegative" {
    const resp = Response{ .code = 550, .message = "Not found", .owned_message = "Not found", .multiline = false };
    try testing.expect(!resp.isSuccess());
    try testing.expect(!resp.isPositive());
    try testing.expect(resp.isNegative());
}

test "TransferMode toString" {
    try testing.expectEqualStrings("A", TransferMode.ascii.toString());
    try testing.expectEqualStrings("I", TransferMode.binary.toString());
}

test "parsePasvAddress" {
    const addr = parsePasvAddress("227 Entering Passive Mode (192,168,1,1,4,1)").?;
    const ipv4 = addr.in;
    const bytes = @as(*const [4]u8, @ptrCast(&ipv4.sa.addr));
    try testing.expectEqual(@as(u8, 192), bytes[0]);
    try testing.expectEqual(@as(u8, 168), bytes[1]);
    try testing.expectEqual(@as(u8, 1), bytes[2]);
    try testing.expectEqual(@as(u8, 1), bytes[3]);
    try testing.expectEqual(@as(u16, 1025), addr.getPort());
}

test "parsePasvAddress invalid" {
    try testing.expect(parsePasvAddress("227 no parens") == null);
    try testing.expect(parsePasvAddress("227 (1,2,3)") == null);
    try testing.expect(parsePasvAddress("227 (256,0,0,0,0,0)") == null);
}

test "parseEpsvAddress" {
    const addr = parseEpsvAddress("229 Entering Extended Passive Mode (|||5000|)").?;
    try testing.expectEqual(@as(u16, 5000), addr.getPort());
}

test "parseEpsvAddress invalid" {
    try testing.expect(parseEpsvAddress("229 no pipe") == null);
    try testing.expect(parseEpsvAddress("229 (|||abc|)") == null);
}

test "FtpConfig defaults" {
    const config = FtpConfig{
        .allocator = testing.allocator,
        .host = "127.0.0.1",
    };
    try testing.expectEqual(@as(u16, 21), config.port);
    try testing.expectEqual(@as(u64, 30_000), config.timeout_ms);
    try testing.expectEqual(ConnectionMode.passive, config.connection_mode);
    try testing.expectEqual(TransferMode.binary, config.transfer_mode);
    try testing.expect(config.tls == null);
}

test "DirectoryEntry defaults" {
    const entry = DirectoryEntry{ .name = "test.txt", .is_directory = false };
    try testing.expectEqualStrings("test.txt", entry.name);
    try testing.expect(!entry.is_directory);
    try testing.expect(!entry.is_symlink);
    try testing.expect(entry.size == null);
    try testing.expect(entry.modified == null);
}

test "Features defaults" {
    const features = Features{};
    try testing.expect(!features.epsv);
    try testing.expect(!features.eprt);
    try testing.expect(!features.size);
    try testing.expect(!features.mdtm);
    try testing.expect(!features.rest);
}

test "FtpError exists" {
    const err = FtpError.ConnectionFailed;
    _ = err;
}
