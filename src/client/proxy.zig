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
    // 1. Initial Greeting / Negotiation
    var greeting: [4]u8 = undefined;
    greeting[0] = 0x05;
    if (proxy.username) |_| {
        greeting[1] = 0x02;
        greeting[2] = 0x00; // No auth
        greeting[3] = 0x02; // Username/Password
        try socket.sendAll(greeting[0..4]);
    } else {
        greeting[1] = 0x01;
        greeting[2] = 0x00; // No auth
        try socket.sendAll(greeting[0..3]);
    }

    var method_reply: [2]u8 = undefined;
    try readNoEof(socket, &method_reply);
    if (method_reply[0] != 0x05 or method_reply[1] == 0xff) return error.ProxyConnectionFailed;

    // 2. Authentication if required
    if (method_reply[1] == 0x02) {
        const username = proxy.username orelse return error.ProxyConnectionFailed;
        const password = proxy.password orelse "";
        if (username.len > 255 or password.len > 255) return error.ProxyConnectionFailed;

        var auth_buf: [516]u8 = undefined;
        auth_buf[0] = 0x01; // Version
        auth_buf[1] = @intCast(username.len);
        @memcpy(auth_buf[2 .. 2 + username.len], username);

        const pass_offset = 2 + username.len;
        auth_buf[pass_offset] = @intCast(password.len);
        @memcpy(auth_buf[pass_offset + 1 .. pass_offset + 1 + password.len], password);

        const total_auth_len = pass_offset + 1 + password.len;
        try socket.sendAll(auth_buf[0..total_auth_len]);

        var auth_reply: [2]u8 = undefined;
        try readNoEof(socket, &auth_reply);
        if (auth_reply[0] != 0x01 or auth_reply[1] != 0x00) return error.ProxyConnectionFailed;
    } else if (method_reply[1] != 0x00) {
        return error.ProxyConnectionFailed;
    }

    // 3. Connect Request
    if (address_mod.isIpAddress(target_host)) {
        const ip = try compat.Address.parseIp(target_host, target_port);
        const ip_addr = ip.toIpAddress();
        switch (ip_addr) {
            .ip4 => |ip4| {
                var req_buf: [10]u8 = undefined;
                req_buf[0] = 0x05; // SOCKS5
                req_buf[1] = 0x01; // CONNECT
                req_buf[2] = 0x00; // Reserved
                req_buf[3] = 0x01; // IPv4
                @memcpy(req_buf[4..8], &ip4.bytes);
                mem.writeInt(u16, req_buf[8..10][0..2], target_port, .big);
                try socket.sendAll(&req_buf);
            },
            .ip6 => |ip6| {
                var req_buf: [22]u8 = undefined;
                req_buf[0] = 0x05; // SOCKS5
                req_buf[1] = 0x01; // CONNECT
                req_buf[2] = 0x00; // Reserved
                req_buf[3] = 0x04; // IPv6
                @memcpy(req_buf[4..20], &ip6.bytes);
                mem.writeInt(u16, req_buf[20..22][0..2], target_port, .big);
                try socket.sendAll(&req_buf);
            },
        }
    } else {
        if (target_host.len > 255) return error.ProxyConnectionFailed;

        var req_buf: [262]u8 = undefined;
        req_buf[0] = 0x05; // SOCKS5
        req_buf[1] = 0x01; // CONNECT
        req_buf[2] = 0x00; // Reserved
        req_buf[3] = 0x03; // Domain name
        req_buf[4] = @intCast(target_host.len);
        @memcpy(req_buf[5 .. 5 + target_host.len], target_host);

        const port_offset = 5 + target_host.len;
        mem.writeInt(u16, req_buf[port_offset..][0..2], target_port, .big);

        try socket.sendAll(req_buf[0 .. port_offset + 2]);
    }

    // 4. Connect Response
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
