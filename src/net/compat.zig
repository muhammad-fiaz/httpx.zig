const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;

pub const Ip4Address = Io.net.Ip4Address;
pub const Ip6Address = Io.net.Ip6Address;

pub const Address = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return fromIpAddress(.{ .ip4 = .{ .bytes = bytes, .port = port } });
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return fromIpAddress(.{ .ip6 = .{
            .bytes = bytes,
            .port = port,
            .flow = flowinfo,
            .interface = .{ .index = scope_id },
        } });
    }

    pub fn parseIp(text: []const u8, port: u16) !Address {
        const ip = try Io.net.IpAddress.resolve(defaultIo(), text, port);
        return fromIpAddress(ip);
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        const family: u16 = @intCast(self.any.family);
        const af4: u16 = @intCast(posix.AF.INET);
        const af6: u16 = @intCast(posix.AF.INET6);

        if (family == af4) return @sizeOf(posix.sockaddr.in);
        if (family == af6) return @sizeOf(posix.sockaddr.in6);
        return @sizeOf(posix.sockaddr);
    }

    pub fn getPort(self: Address) u16 {
        const family: u16 = @intCast(self.any.family);
        const af4: u16 = @intCast(posix.AF.INET);
        const af6: u16 = @intCast(posix.AF.INET6);

        if (family == af4) return std.mem.bigToNative(u16, self.in.port);
        if (family == af6) return std.mem.bigToNative(u16, self.in6.port);
        return 0;
    }

    pub fn setPort(self: *Address, port: u16) void {
        const family: u16 = @intCast(self.any.family);
        const af4: u16 = @intCast(posix.AF.INET);
        const af6: u16 = @intCast(posix.AF.INET6);

        if (family == af4) {
            self.in.port = std.mem.nativeToBig(u16, port);
        } else if (family == af6) {
            self.in6.port = std.mem.nativeToBig(u16, port);
        }
    }

    pub fn toIpAddress(self: Address) Io.net.IpAddress {
        const family: u16 = @intCast(self.any.family);
        const af4: u16 = @intCast(posix.AF.INET);

        if (family == af4) {
            var bytes: [4]u8 = undefined;
            const net_addr = std.mem.nativeToBig(u32, self.in.addr);
            std.mem.writeInt(u32, &bytes, net_addr, .big);
            return .{ .ip4 = .{
                .bytes = bytes,
                .port = std.mem.bigToNative(u16, self.in.port),
            } };
        }

        return .{ .ip6 = .{
            .bytes = self.in6.addr,
            .port = std.mem.bigToNative(u16, self.in6.port),
            .flow = self.in6.flowinfo,
            .interface = .{ .index = self.in6.scope_id },
        } };
    }

    pub fn format(self: Address, w: *Io.Writer) Io.Writer.Error!void {
        return self.toIpAddress().format(w);
    }
};

pub const AddressList = struct {
    addrs: []Address,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AddressList) void {
        self.allocator.free(self.addrs);
        self.* = undefined;
    }
};

fn defaultIo() Io {
    return if (builtin.is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn fromIpAddress(ip: Io.net.IpAddress) Address {
    return switch (ip) {
        .ip4 => |ip4| blk: {
            var out: Address = undefined;
            out.in = std.mem.zeroes(posix.sockaddr.in);
            out.in.family = @intCast(posix.AF.INET);
            out.in.port = std.mem.nativeToBig(u16, ip4.port);
            // Keep sockaddr.in.addr in network byte order in memory on little-endian hosts.
            const net_addr = std.mem.readInt(u32, &ip4.bytes, .big);
            out.in.addr = std.mem.bigToNative(u32, net_addr);
            break :blk out;
        },
        .ip6 => |ip6| blk: {
            var out: Address = undefined;
            out.in6 = std.mem.zeroes(posix.sockaddr.in6);
            out.in6.family = @intCast(posix.AF.INET6);
            out.in6.port = std.mem.nativeToBig(u16, ip6.port);
            out.in6.flowinfo = ip6.flow;
            out.in6.addr = ip6.bytes;
            out.in6.scope_id = ip6.interface.index;
            break :blk out;
        },
    };
}

/// Parses an IPv4/IPv6 address and applies a port.
pub fn parseIp(text: []const u8, port: u16) !Address {
    return Address.parseIp(text, port);
}

/// Resolves a host name to one or more IP addresses.
pub fn getAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !AddressList {
    if (parseIp(host, port)) |ip| {
        const addrs = try allocator.alloc(Address, 1);
        addrs[0] = ip;
        return .{ .addrs = addrs, .allocator = allocator };
    } else |_| {}

    const io = defaultIo();
    const host_name: Io.net.HostName = try .init(host);

    var queue_buffer: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&queue_buffer);

    try Io.net.HostName.lookup(host_name, io, &queue, .{ .port = port });

    var addrs = std.ArrayList(Address).empty;
    errdefer addrs.deinit(allocator);

    while (queue.getOneUncancelable(io)) |item| {
        switch (item) {
            .address => |addr| try addrs.append(allocator, fromIpAddress(addr)),
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
    }

    if (addrs.items.len == 0) return error.DnsResolutionFailed;

    return .{ .addrs = try addrs.toOwnedSlice(allocator), .allocator = allocator };
}

test "Address IPv4 round trip preserves bytes and port" {
    const ip_bytes: [4]u8 = .{ 127, 0, 0, 1 };
    const addr = Address.initIp4(ip_bytes, 8080);
    const ip = addr.toIpAddress();

    try std.testing.expectEqualDeep(ip_bytes, ip.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 8080), ip.ip4.port);
}
