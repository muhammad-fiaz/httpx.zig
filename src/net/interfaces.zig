//! Network Interface Discovery for httpx.zig
//!
//! Cross-platform network interface enumeration for binding and address selection.
//! Uses GetAdaptersAddresses on Windows and getifaddrs on POSIX.

const std = @import("std");
const posix = std.posix;
const net = @import("compat.zig");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const address_mod = @import("address.zig");

const is_windows = builtin.os.tag == .windows;

const DEFAULT_MTU: u32 = 1500;

pub const InterfaceFlags = packed struct(u32) {
    up: bool = false,
    broadcast: bool = false,
    loopback: bool = false,
    point_to_point: bool = false,
    multicast: bool = false,
    _padding: u27 = 0,
};

pub const InterfaceInfo = struct {
    name: []const u8,
    addresses: []net.Address,
    flags: InterfaceFlags,
    mtu: u32,

    pub fn deinit(self: *InterfaceInfo, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.addresses);
    }
};

pub const InterfaceList = struct {
    interfaces: []InterfaceInfo,
    allocator: Allocator,

    pub fn deinit(self: *InterfaceList) void {
        for (self.interfaces) |*iface| {
            iface.deinit(self.allocator);
        }
        self.allocator.free(self.interfaces);
    }

    pub fn findByName(self: InterfaceList, name: []const u8) ?InterfaceInfo {
        for (self.interfaces) |iface| {
            if (std.mem.eql(u8, iface.name, name)) return iface;
        }
        return null;
    }

    pub fn findByAddress(self: InterfaceList, addr: net.Address) ?InterfaceInfo {
        for (self.interfaces) |iface| {
            for (iface.addresses) |iface_addr| {
                if (std.meta.eql(iface_addr.any, addr.any)) return iface;
            }
        }
        return null;
    }
};

pub fn listInterfaces(allocator: Allocator) !InterfaceList {
    if (is_windows) {
        const result = listInterfacesWindows(allocator) catch |err| {
            return err;
        };
        return result;
    }
    const result = listInterfacesPosix(allocator) catch |err| {
        return err;
    };
    return result;
}

pub fn listLocalAddresses(allocator: Allocator) ![]net.Address {
    const ifaces = try listInterfaces(allocator);
    defer ifaces.deinit();

    var addrs = std.ArrayList(net.Address).empty;
    errdefer addrs.deinit(allocator);

    for (ifaces.interfaces) |iface| {
        for (iface.addresses) |addr| {
            if (address_mod.isLoopback(addr) or address_mod.isLinkLocal(addr)) continue;
            try addrs.append(allocator, addr);
        }
    }
    return try addrs.toOwnedSlice(allocator);
}

pub fn listLoopbackAddresses(allocator: Allocator) ![]net.Address {
    const ifaces = try listInterfaces(allocator);
    defer ifaces.deinit();

    var addrs = std.ArrayList(net.Address).empty;
    errdefer addrs.deinit(allocator);

    for (ifaces.interfaces) |iface| {
        if (!iface.flags.loopback) continue;
        for (iface.addresses) |addr| {
            try addrs.append(allocator, addr);
        }
    }
    return try addrs.toOwnedSlice(allocator);
}

const ifaddrs_header = if (!is_windows) struct {
    const ifaddrs = extern struct {
        ifa_next: ?*ifaddrs,
        ifa_name: [*:0]const u8,
        ifa_flags: c_uint,
        ifa_addr: ?*posix.sockaddr,
        ifa_netmask: ?*posix.sockaddr,
        ifa_ifu: ?*anyopaque,
        ifa_data: ?*anyopaque,
    };

    extern "c" fn getifaddrs(ifap: *?*ifaddrs) c_int;
    extern "c" fn freeifaddrs(ifap: *ifaddrs) void;
} else struct {};

fn listInterfacesPosix(allocator: Allocator) !InterfaceList {
    var ifap: ?ifaddrs_header.ifaddrs = null;
    if (ifaddrs_header.getifaddrs(&ifap) != 0) {
        return error.InterfaceQueryFailed;
    }
    defer ifaddrs_header.freeifaddrs(ifap.?);

    var ifaces = std.ArrayList(InterfaceInfo).empty;
    errdefer ifaces.deinit(allocator);

    var current = ifap;
    while (current) |ifa| : (current = ifa.ifa_next) {
        const sockaddr = ifa.ifa_addr orelse continue;
        const family = sockaddr.family;

        if (family != posix.AF.INET and family != posix.AF.INET6) continue;

        const name_raw = std.mem.sliceTo(ifa.ifa_name, 0);
        const name = try allocator.dupe(u8, name_raw);

        var flags: InterfaceFlags = .{};
        if ((ifa.ifa_flags & 0x1) != 0) flags.up = true; // IFF_UP
        if ((ifa.ifa_flags & 0x2) != 0) flags.broadcast = true; // IFF_BROADCAST
        if ((ifa.ifa_flags & 0x8) != 0) flags.loopback = true; // IFF_LOOPBACK
        if ((ifa.ifa_flags & 0x10) != 0) flags.point_to_point = true; // IFF_POINTOPOINT
        if ((ifa.ifa_flags & 0x800) != 0) flags.multicast = true; // IFF_MULTICAST

        const addr = net.Address{
            .any = sockaddr.*,
        };

        const addr_slice = try allocator.dupe(net.Address, &[_]net.Address{addr});

        try ifaces.append(allocator, .{
            .name = name,
            .addresses = addr_slice,
            .flags = flags,
            .mtu = DEFAULT_MTU,
        });
    }

    return .{
        .interfaces = try ifaces.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const Windows = if (is_windows) struct {
    const GetAdaptersAddressesFlags = packed struct(u32) {
        skip_unicast: bool = false,
        skip_anycast: bool = false,
        skip_multicast: bool = false,
        skip_dns_server: bool = false,
        include_prefixes: bool = false,
        include_wins: bool = false,
        include_gateways: bool = false,
        _padding: u25 = 0,
    };

    const SocketAddress = extern struct {
        lp_socket_handle: ?*anyopaque,
        lp_sa: *posix.sockaddr,
    };

    const AdapterAddress = extern struct {
        length: u32,
        flags: u32,
        next: ?*AdapterAddress,
        adapter_name: ?[*:0]u16,
        first_unicast: ?*UnicastAddress,
        first_anycast: ?*AnycastAddress,
        first_multicast: ?*MulticastAddress,
        first_dns_server: ?*DnsServerAddress,
        dns_suffix: ?[*:0]u16,
        description: ?[*:0]u16,
        friendly_name: ?[*:0]u16,
        physical_address: [8]u8,
        physical_address_length: u32,
        flags_v4: u32,
        mtu: u32,
        if_type: u32,
        oper_status: u32,
    };

    const UnicastAddress = extern struct {
        flags: u32,
        next: ?*UnicastAddress,
        address: SocketAddress,
        prefix_origin: u32,
        suffix_origin: u32,
        dad_state: u32,
        valid_lifetime: u32,
        preferred_lifetime: u32,
        lease_lifetime: u32,
        on_link_prefix_length: u8,
    };

    const AnycastAddress = extern struct {
        _padding: [24]u8,
    };

    const MulticastAddress = extern struct {
        _padding: [24]u8,
    };

    const DnsServerAddress = extern struct {
        _padding: [16]u8,
    };

    const ERROR_BUFFER_OVERFLOW: u32 = 111;
    const ERROR_NO_DATA: u32 = 232;

    extern "iphlpapi" fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: ?*anyopaque,
        adapter_addresses: ?*AdapterAddress,
        size_pointer: *u32,
    ) u32;

    fn wideToUtf8(allocator: Allocator, wide: [*:0]u16) ![]u8 {
        var len: usize = 0;
        while (wide[len] != 0) : (len += 1) {}
        // Worst case: each u16 can produce up to 3 UTF-8 bytes.
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const cp: u21 = wide[i];
            if (cp < 0x80) {
                try result.append(allocator, @intCast(cp));
            } else if (cp < 0x800) {
                try result.append(allocator, @intCast(0xC0 | (cp >> 6)));
                try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
            } else {
                try result.append(allocator, @intCast(0xE0 | (cp >> 12)));
                try result.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
            }
        }
        return result.toOwnedSlice(allocator);
    }
} else struct {};

fn listInterfacesWindows(allocator: Allocator) !InterfaceList {
    var buf_len: u32 = 15000;
    var buf = try allocator.alloc(u8, buf_len);
    defer allocator.free(buf);

    var ifaces = std.ArrayList(InterfaceInfo).empty;
    errdefer ifaces.deinit(allocator);

    while (true) {
        const rc = Windows.GetAdaptersAddresses(
            posix.AF.UNSPEC,
            0x0100, // GAA_FLAG_SKIP_ANYCAST
            null,
            @ptrCast(@alignCast(buf.ptr)),
            &buf_len,
        );

        if (rc == 0) break;
        if (rc == Windows.ERROR_BUFFER_OVERFLOW) {
            allocator.free(buf);
            buf = try allocator.alloc(u8, buf_len);
            continue;
        }
        return error.InterfaceQueryFailed;
    }

    var adapter: ?*Windows.AdapterAddress = @ptrCast(@alignCast(buf.ptr));
    while (adapter) |a| : (adapter = a.next) {
        const name_raw = a.adapter_name orelse continue;
        const name = try Windows.wideToUtf8(allocator, name_raw);

        var flags: InterfaceFlags = .{};
        if ((a.flags & 0x1) != 0) flags.up = true;

        var addrs = std.ArrayList(net.Address).empty;
        errdefer addrs.deinit(allocator);

        var unicast = a.first_unicast;
        while (unicast) |u| : (unicast = u.next) {
            const sa = u.address.lp_sa;
            if (sa.family == posix.AF.INET or sa.family == posix.AF.INET6) {
                try addrs.append(allocator, .{ .any = sa.* });
            }
        }

        if (addrs.items.len > 0) {
            const addr_slice = try addrs.toOwnedSlice(allocator);
            try ifaces.append(allocator, .{
                .name = name,
                .addresses = addr_slice,
                .flags = flags,
                .mtu = a.mtu,
            });
        } else {
            allocator.free(name);
        }
    }

    return .{
        .interfaces = try ifaces.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

test "listInterfaces returns at least one interface" {
    var ifaces = listInterfaces(std.testing.allocator) catch |err| {
        if (err == error.InterfaceQueryFailed) return;
        return err;
    };
    defer ifaces.deinit();
    try std.testing.expect(ifaces.interfaces.len > 0);
}

test "listInterfaces finds loopback" {
    var ifaces = listInterfaces(std.testing.allocator) catch |err| {
        if (err == error.InterfaceQueryFailed) return;
        return err;
    };
    defer ifaces.deinit();

    var found_loopback = false;
    for (ifaces.interfaces) |iface| {
        if (iface.flags.loopback) {
            found_loopback = true;
            break;
        }
    }
    try std.testing.expect(found_loopback);
}

test "listLocalAddresses excludes loopback" {
    const addrs = listLocalAddresses(std.testing.allocator) catch return;
    defer std.testing.allocator.free(addrs);
    for (addrs) |addr| {
        try std.testing.expect(!address_mod.isLoopback(addr));
    }
}

test "listLoopbackAddresses returns loopback only" {
    const addrs = listLoopbackAddresses(std.testing.allocator) catch return;
    defer std.testing.allocator.free(addrs);
    for (addrs) |addr| {
        try std.testing.expect(address_mod.isLoopback(addr));
    }
}

test "InterfaceList findByName" {
    var ifaces = listInterfaces(std.testing.allocator) catch return;
    defer ifaces.deinit();
    if (ifaces.interfaces.len > 0) {
        const first = ifaces.interfaces[0];
        try std.testing.expect(ifaces.findByName(first.name) != null);
        try std.testing.expect(ifaces.findByName("nonexistent_interface_xyz") == null);
    }
}
