const std = @import("std");
const mem = std.mem;

const Socket = @import("../net/socket.zig").Socket;
const types = @import("../core/types.zig");
const address_mod = @import("../net/address.zig");
const compat = @import("../net/compat.zig");

fn readNoEof(socket: *Socket, out: []u8) !void {
    var read: usize = 0;
    while (read < out.len) {
        const n = try socket.recv(out[read..]);
        if (n == 0) return error.UnexpectedEof;
        read += n;
    }
}

fn writeSocksPort(socket: *Socket, port: u16) !void {
    var port_bytes: [2]u8 = undefined;
    mem.writeInt(u16, &port_bytes, port, .big);
    try socket.sendAll(&port_bytes);
}

fn connectSocks5hTunnel(socket: *Socket, target_host: []const u8, target_port: u16, proxy: types.Proxy) !void {
    var greeting: [4]u8 = undefined;
    greeting[0] = 0x05;
    if (proxy.username) |_| {
        greeting[1] = 0x02;
        greeting[2] = 0x00;
        greeting[3] = 0x02;
        try socket.sendAll(greeting[0..4]);
    } else {
        greeting[1] = 0x01;
        greeting[2] = 0x00;
        try socket.sendAll(greeting[0..3]);
    }

    var method_reply: [2]u8 = undefined;
    try readNoEof(socket, &method_reply);
    if (method_reply[0] != 0x05 or method_reply[1] == 0xff) return error.ProxyConnectionFailed;

    if (method_reply[1] == 0x02) {
        const username = proxy.username orelse return error.ProxyConnectionFailed;
        const password = proxy.password orelse "";
        if (username.len > 255 or password.len > 255) return error.ProxyConnectionFailed;

        var auth_header: [2]u8 = .{ 0x01, @intCast(username.len) };
        try socket.sendAll(&auth_header);
        try socket.sendAll(username);

        var password_len: [1]u8 = .{@intCast(password.len)};
        try socket.sendAll(&password_len);
        try socket.sendAll(password);

        var auth_reply: [2]u8 = undefined;
        try readNoEof(socket, &auth_reply);
        if (auth_reply[0] != 0x01 or auth_reply[1] != 0x00) return error.ProxyConnectionFailed;
    } else if (method_reply[1] != 0x00) {
        return error.ProxyConnectionFailed;
    }

    if (address_mod.isIpAddress(target_host)) {
        const ip = try compat.Address.parseIp(target_host, target_port);
        const ip_addr = ip.toIpAddress();
        switch (ip_addr) {
            .ip4 => |ip4| {
                var header: [4]u8 = .{ 0x05, 0x01, 0x00, 0x01 };
                try socket.sendAll(&header);
                try socket.sendAll(&ip4.bytes);
            },
            .ip6 => |ip6| {
                var header: [4]u8 = .{ 0x05, 0x01, 0x00, 0x04 };
                try socket.sendAll(&header);
                try socket.sendAll(&ip6.bytes);
            },
        }
    } else {
        if (target_host.len > 255) return error.ProxyConnectionFailed;
        var header: [4]u8 = .{ 0x05, 0x01, 0x00, 0x03 };
        try socket.sendAll(&header);

        var host_len: [1]u8 = .{@intCast(target_host.len)};
        try socket.sendAll(&host_len);
        try socket.sendAll(target_host);
    }

    try writeSocksPort(socket, target_port);

    var reply_head: [4]u8 = undefined;
    try readNoEof(socket, &reply_head);
    if (reply_head[0] != 0x05 or reply_head[1] != 0x00) return error.ProxyConnectionFailed;

    const atyp = reply_head[3];
    switch (atyp) {
        0x01 => {
            var skip: [4]u8 = undefined;
            try readNoEof(socket, &skip);
        },
        0x03 => {
            var len: [1]u8 = undefined;
            try readNoEof(socket, &len);
            if (len[0] > 0) {
                var skip: [255]u8 = undefined;
                try readNoEof(socket, skip[0..len[0]]);
            }
        },
        0x04 => {
            var skip: [16]u8 = undefined;
            try readNoEof(socket, &skip);
        },
        else => return error.ProxyConnectionFailed,
    }

    var skip_port: [2]u8 = undefined;
    try readNoEof(socket, &skip_port);
}

/// Establishes a SOCKS5h tunnel to the target host and port.
pub fn establishSocks5hTunnel(socket: *Socket, target_host: []const u8, target_port: u16, proxy: types.Proxy) !void {
    try connectSocks5hTunnel(socket, target_host, target_port, proxy);
}
